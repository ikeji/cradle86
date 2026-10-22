#!/usr/bin/env python3
"""Virtual disk server for the HIDOS VM on cradle86.

Serves a disk to the V30 over USB serial port 3 ("Virtual Disk", interface 6)
as DOS drive B: (read/write). A: is always the read-only disk.img embedded in
flash. While this server is not running, B: is "not ready".

The disk is either
  - a FAT12 image file. Use the same sector size as A: (4096,
    `mkfs.fat -S 4096 -F 12`): DOS sizes its sector buffers from the drives
    seen at boot.
  - a directory on the PC. A FAT12 image of it is built in memory, and what
    DOS writes is copied back to the directory (file create/write/delete,
    rename, mkdir/rmdir) after the disk has been idle for a moment. Files
    changed on the PC are seen by DOS as a disk change (the image is rebuilt).
    Long or non-8.3 names are shown as e.g. LONGNA~1.TXT; files that DOS
    creates get lowercase names on the PC. Names starting with '.' are hidden.
    Don't change the same file from both sides at once, and don't FORMAT B:.

Protocol (little endian), see io_disk/disk_poll in main.cpp:
  request  'DK' op drive seq(u32) offset(u32) length(u32)  [+ length bytes for 'W']
  response 'kd' op status seq(u32) value(u32) 0(u32)       [+ value bytes for 'R']

Usage: ./disk_server.py b.img
       ./disk_server.py some/directory
"""

import argparse
import collections
import glob
import os
import struct
import sys
import time

import serial

HDR = struct.Struct('<2sBBIII')

MEDIA_UNCHANGED = 1
MEDIA_CHANGED = 0xFFFF


def find_port():
    ports = sorted(glob.glob('/dev/serial/by-id/*cradle86*-if06'))
    if not ports:
        sys.exit('cradle86 disk port not found. Use --port.')
    return ports[0]


class ImageDrive:
    def __init__(self, path, readonly):
        self.path = path
        self.f = open(path, 'rb' if readonly else 'r+b')
        self.readonly = readonly
        self.mtime = os.fstat(self.f.fileno()).st_mtime_ns

    def read(self, off, length):
        self.f.seek(off)
        data = self.f.read(length)
        return data if len(data) == length else None

    def write(self, off, data):
        if self.readonly:
            return False
        self.f.seek(off)
        self.f.write(data)
        self.f.flush()
        self.mtime = os.fstat(self.f.fileno()).st_mtime_ns
        return True

    def media_check(self):
        # Like hidosvm: a changed timestamp (e.g. mcopy from the PC while DOS
        # runs) is reported as a media change.
        mtime = os.stat(self.path).st_mtime_ns
        if mtime == self.mtime:
            return MEDIA_UNCHANGED
        self.mtime = mtime
        return MEDIA_CHANGED

    def idle(self):
        pass


# --- FAT12 directory drive ---

SECTOR = 4096
MAX_CLUSTERS = 4084  # FAT12 (DOS 2 has no FAT16)
ROOT_ENTRIES = 512
ATTR_VOL, ATTR_DIR = 0x08, 0x10
NAME_CHARS = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()-@^_`{}~")


def name83(name):
    """'foo.txt' -> b'FOO     TXT', or None if it is not a valid 8.3 name."""
    base, dot, ext = name.upper().partition('.')
    try:
        base, ext = base.encode('ascii'), ext.encode('ascii')
    except UnicodeEncodeError:
        return None
    if not 1 <= len(base) <= 8 or len(ext) > 3 or (dot and not ext):
        return None
    if not set(base + ext) <= NAME_CHARS:
        return None
    return base.ljust(8) + ext.ljust(3)


def mangle83(name, used):
    base, _, ext = name.upper().rpartition('.') if '.' in name.lstrip('.') \
        else (name.upper(), '', '')
    def clean(s):
        return bytes(c for c in s.encode('ascii', 'ignore')
                     if c in NAME_CHARS and c != ord('~'))
    base, ext = clean(base) or b'FILE', clean(ext)[:3]
    for n in range(1, 100000):
        tail = b'~%d' % n
        n83 = (base[:8 - len(tail)] + tail).ljust(8) + ext.ljust(3)
        if n83 not in used:
            return n83
    raise RuntimeError('too many similar names')


def show83(n83):
    base, ext = n83[:8].rstrip(), n83[8:].rstrip()
    return (base + (b'.' + ext if ext else b'')).decode('ascii')


def dos_datetime(mtime):
    t = time.localtime(mtime)
    year = min(max(t.tm_year, 1980), 2107)
    return (t.tm_hour << 11 | t.tm_min << 5 | t.tm_sec // 2,
            (year - 1980) << 9 | t.tm_mon << 5 | t.tm_mday)


def listdir(path):
    """Directory entries to show to DOS: (name, is_dir, stat)."""
    out = []
    for de in sorted(os.scandir(path), key=lambda de: de.name):
        if de.name.startswith('.'):
            continue
        try:
            if de.is_dir(follow_symlinks=False):
                out.append((de.name, True, de.stat(follow_symlinks=False)))
            elif de.is_file():
                out.append((de.name, False, de.stat()))
        except OSError:
            pass
    return out


def snapshot(root):
    snap = {}
    def walk(rel):
        for name, is_dir, st in listdir(os.path.join(root, rel)):
            r = os.path.join(rel, name)
            snap[r] = (is_dir, st.st_size, st.st_mtime_ns)
            if is_dir:
                walk(r)
    walk('')
    return snap


class Node:
    def __init__(self, n83, linux, is_dir, size, mtime):
        self.n83, self.linux, self.is_dir = n83, linux, is_dir
        self.size, self.mtime = size, mtime
        self.children, self.start = [], 0


def build_image(root, names, free):
    """Builds a FAT12 image of the directory `root`.

    `names` maps PC paths to their previous 8.3 names, so that a name stays
    the same across rebuilds. Returns (image, {DOS path: PC path}).
    """
    def scan(rel):
        nodes, used = [], set()
        entries = listdir(os.path.join(root, rel))
        # Names that are valid 8.3 (or were used before) take priority, so a
        # mangled name never steals one.
        for name, is_dir, st in entries:
            r = os.path.join(rel, name)
            n83 = names.get(r) or name83(name)
            if n83 and n83 not in used:
                used.add(n83)
                nodes.append(Node(n83, r, is_dir, st.st_size, st.st_mtime))
        done = {n.linux for n in nodes}
        for name, is_dir, st in entries:
            r = os.path.join(rel, name)
            if r not in done:
                n83 = mangle83(name, used)
                used.add(n83)
                nodes.append(Node(n83, r, is_dir, st.st_size, st.st_mtime))
        for n in nodes:
            if n.is_dir:
                n.children = scan(n.linux)
        return nodes

    top = scan('')
    if len(top) > ROOT_ENTRIES:
        raise RuntimeError(f'too many files in the top directory (max {ROOT_ENTRIES})')

    def walk(nodes):
        for n in nodes:
            yield n
            if n.is_dir:
                yield from walk(n.children)

    def clusters(n, cb):
        size = (len(n.children) + 2) * 32 if n.is_dir else n.size
        return -(-size // cb)

    spc = 1
    while True:
        cb = SECTOR * spc
        used = sum(clusters(n, cb) for n in walk(top))
        total = min(used + -(-free // cb), MAX_CLUSTERS)
        if used <= total:
            break
        spc *= 2
        if spc > 16:
            raise RuntimeError('directory too large for FAT12')
    fat_secs = -(-((total + 2) * 3 // 2 + 1) // SECTOR)
    root_secs = ROOT_ENTRIES * 32 // SECTOR
    data_sec = 1 + 2 * fat_secs + root_secs
    sectors = data_sec + total * spc
    img = bytearray(sectors * SECTOR)

    img[0:3] = b'\xeb\x3c\x90'
    img[3:11] = b'CRADLE86'
    struct.pack_into('<HBHBHHBHHHI', img, 11, SECTOR, spc, 1, 2, ROOT_ENTRIES,
                     sectors, 0xF8, fat_secs, 16, 2, 0)
    img[510:512] = b'\x55\xaa'

    fat = Fat(img)
    fat.set(0, 0xFF8)
    fat.set(1, 0xFFF)
    next_cluster = 2
    for n in walk(top):
        count = clusters(n, cb)
        if count:
            n.start = next_cluster
            for c in range(next_cluster, next_cluster + count):
                fat.set(c, c + 1 if c + 1 < next_cluster + count else 0xFFF)
            next_cluster += count

    def dirent(n83, attr, start, size, mtime):
        tm, dt = dos_datetime(mtime)
        return struct.pack('<11sB10sHHHI', n83, attr, b'', tm, dt, start, size)

    def fill_dir(off, nodes, me, parent):
        if me:
            img[off:off + 64] = (
                dirent(b'.'.ljust(11), ATTR_DIR, me.start, 0, me.mtime) +
                dirent(b'..'.ljust(11), ATTR_DIR, parent.start if parent else 0,
                       0, me.mtime))
            off += 64
        for n in nodes:
            img[off:off + 32] = dirent(n.n83, ATTR_DIR if n.is_dir else 0,
                                       n.start, 0 if n.is_dir else n.size,
                                       n.mtime)
            off += 32

    def cluster_off(c):
        return (data_sec + (c - 2) * spc) * SECTOR

    fill_dir((1 + 2 * fat_secs) * SECTOR, top, None, None)
    dospaths = {}
    def fill(nodes, parent, prefix):
        for n in nodes:
            path = prefix + show83(n.n83)
            dospaths[path] = n.linux
            if n.is_dir:
                fill_dir(cluster_off(n.start), n.children, n, parent)
                fill(n.children, n, path + '/')
            elif n.size:
                with open(os.path.join(root, n.linux), 'rb') as f:
                    data = f.read(n.size)
                off = cluster_off(n.start)
                img[off:off + len(data)] = data
    fill(top, None, '')
    img[(1 + fat_secs) * SECTOR:data_sec * SECTOR - root_secs * SECTOR] = \
        img[SECTOR:(1 + fat_secs) * SECTOR]  # second FAT
    return img, dospaths


class Fat:
    """FAT12 view of an image (first FAT)."""

    def __init__(self, img):
        self.img = img
        (self.bps, self.spc, res, nfats, self.root_entries, sectors, _,
         self.fat_secs) = struct.unpack_from('<HBHBHHBH', img, 11)
        self.fat_off = res * self.bps
        self.root_off = self.fat_off + nfats * self.fat_secs * self.bps
        self.data_off = self.root_off + self.root_entries * 32
        self.cb = self.bps * self.spc
        self.clusters = (sectors * self.bps - self.data_off) // self.cb

    def get(self, n):
        v = struct.unpack_from('<H', self.img, self.fat_off + n * 3 // 2)[0]
        return v >> 4 if n & 1 else v & 0xFFF

    def set(self, n, v):
        off = self.fat_off + n * 3 // 2
        old = struct.unpack_from('<H', self.img, off)[0]
        v = (old & 0xF) | v << 4 if n & 1 else (old & 0xF000) | v
        struct.pack_into('<H', self.img, off, v)

    def chain(self, start):
        out = []
        c = start
        while 2 <= c < self.clusters + 2 and len(out) <= self.clusters:
            out.append(c)
            c = self.get(c)
        return tuple(out)

    def cluster_data(self, c):
        off = self.data_off + (c - 2) * self.cb
        return self.img[off:off + self.cb]

    def cluster_of(self, off):
        return (off - self.data_off) // self.cb + 2

    def read_dir(self, chain):
        """Yields (8.3 name, attr, start, size) of the live entries."""
        if chain is None:
            data = self.img[self.root_off:self.data_off]
        else:
            data = b''.join(self.cluster_data(c) for c in chain)
        for off in range(0, len(data), 32):
            n83, attr, start, size = struct.unpack_from('<11sB14xHI', data, off)
            if n83[0] == 0:
                break
            if n83[0] == 0xE5 or attr & ATTR_VOL or n83[0] == ord('.'):
                continue
            yield n83, attr, start, size


Ent = collections.namedtuple('Ent', 'n83 is_dir start size chain')


def read_tree(img):
    """{DOS path: Ent} of all files and directories in the image."""
    fat = Fat(img)
    tree = {}
    def walk(chain, prefix, depth):
        for n83, attr, start, size in fat.read_dir(chain):
            path = prefix + show83(n83)
            is_dir = bool(attr & ATTR_DIR)
            sub = fat.chain(start)
            tree[path] = Ent(n83, is_dir, start, size, sub)
            if is_dir and depth < 32:
                walk(sub, path + '/', depth + 1)
    walk(None, '', 0)
    return tree


class DirDrive:
    SYNC_DELAY = 0.3  # seconds without requests before syncing to the PC
    SCAN_INTERVAL = 1.0  # minimum interval between scans of the PC side

    def __init__(self, root, readonly, free):
        self.root = root
        self.readonly = readonly
        self.free = free
        self.names = {}  # PC path -> 8.3 name, kept across rebuilds
        self.rebuild()

    def log(self, msg):
        print(msg, flush=True)

    def rebuild(self):
        self.img, self.pc = build_image(self.root, self.names, self.free)
        self.fat = Fat(self.img)
        self.tree = read_tree(self.img)
        for path, pc in self.pc.items():
            self.names[pc] = self.tree[path].n83
        self.dirty = set()  # clusters written since the last sync
        self.pending = False
        self.broken = False
        self.snap = snapshot(self.root)
        self.last_scan = time.monotonic()
        self.log(f'Built B: from {self.root}: {len(self.tree)} entries, '
                 f'{len(self.img) // 1024}KB')

    def read(self, off, length):
        if off + length > len(self.img):
            return None
        return bytes(self.img[off:off + length])

    def write(self, off, data):
        if self.readonly or off + len(data) > len(self.img):
            return False
        if off < self.fat.fat_off and \
                self.img[off:off + len(data)] != data[:self.fat.fat_off - off]:
            if not self.broken:
                self.log('Boot sector written (FORMAT?): '
                         'no more syncing to the PC until restarted')
            self.broken = True
        self.img[off:off + len(data)] = data
        end = off + len(data)
        if end > self.fat.data_off:
            self.dirty.update(range(self.fat.cluster_of(max(off, self.fat.data_off)),
                                    self.fat.cluster_of(end - 1) + 1))
        self.pending = True
        self.last_write = time.monotonic()
        return True

    def idle(self):
        if self.pending and time.monotonic() - self.last_write >= self.SYNC_DELAY:
            self.sync()

    def media_check(self):
        if self.pending:
            self.sync()
        if self.broken or time.monotonic() - self.last_scan < self.SCAN_INTERVAL:
            return MEDIA_UNCHANGED
        self.last_scan = time.monotonic()
        if snapshot(self.root) == self.snap:
            return MEDIA_UNCHANGED
        self.log('Changed on the PC: rebuilding')
        self.rebuild()
        return MEDIA_CHANGED

    def file_data(self, e):
        data = b''.join(self.fat.cluster_data(c) for c in e.chain)
        return bytes(data[:e.size])

    def sync(self):
        """Copies the changes DOS made to the image back to the directory."""
        self.pending = False
        if self.broken:
            return
        old, old_pc = self.tree, self.pc
        new = read_tree(self.img)
        new_pc = {}
        matched = set()  # old paths that are still alive (maybe renamed)
        old_dir_of = {}  # new dir path -> old dir path
        by_start = {}
        for p, e in old.items():
            if p not in new and e.start:
                by_start.setdefault(e.start, p)
        renamed_dirs = []  # (old PC path, new PC path)

        def cur_pc(oldpath):
            pc = old_pc[oldpath]
            for src, dst in renamed_dirs:
                if pc.startswith(src + os.sep):
                    pc = dst + pc[len(src):]
            return pc

        def changed(o, e):
            return (o.start, o.size, o.chain) != (e.start, e.size, e.chain) or \
                not self.dirty.isdisjoint(e.chain)

        for p in sorted(new, key=lambda p: (p.count('/'), p)):
            e = new[p]
            parent, _, name = p.rpartition('/')
            parent_pc = new_pc[parent] if parent else ''
            oparent = old_dir_of.get(parent, parent)
            okey = oparent + '/' + name if oparent else name
            o = old.get(okey)
            if o is not None and o.is_dir == e.is_dir and okey not in matched:
                pc = os.path.join(parent_pc, os.path.basename(old_pc[okey]))
            else:
                okey = by_start.get(e.start)
                o = old.get(okey)
                pc = os.path.join(parent_pc, name.lower())
                if o is not None and o.is_dir == e.is_dir and okey not in matched:
                    self.log(f'rename {old_pc[okey]} -> {pc}')
                    self.pc_rename(cur_pc(okey), pc)
                    if e.is_dir:
                        renamed_dirs.append((cur_pc(okey), pc))
                else:
                    okey, o = None, None
            if okey:
                matched.add(okey)
            new_pc[p] = pc
            full = os.path.join(self.root, pc)
            if e.is_dir:
                if okey:
                    old_dir_of[p] = okey
                elif not os.path.isdir(full):
                    self.log(f'mkdir {pc}')
                    os.makedirs(full, exist_ok=True)
            elif o is None or changed(o, e):
                data = self.file_data(e)
                if len(data) < e.size:
                    # FAT not written yet: copy what is there, retry next time.
                    new[p] = e._replace(chain=())
                self.log(f'write {pc} ({len(data)} bytes)')
                with open(full, 'wb') as f:
                    f.write(data)

        for p in sorted(set(old) - matched, key=lambda p: -p.count('/')):
            pc = cur_pc(p)
            full = os.path.join(self.root, pc)
            self.log(f'delete {pc}')
            try:
                if old[p].is_dir:
                    os.rmdir(full)
                else:
                    os.remove(full)
            except FileNotFoundError:
                pass
            except OSError as ex:
                self.log(f'  failed: {ex}')

        self.tree, self.pc = new, new_pc
        self.names = {pc: new[p].n83 for p, pc in new_pc.items()}
        self.dirty = set()
        self.snap = snapshot(self.root)

    def pc_rename(self, src, dst):
        try:
            os.rename(os.path.join(self.root, src), os.path.join(self.root, dst))
        except OSError as ex:
            self.log(f'  failed: {ex}')


# --- serial protocol ---

def read_exact(ser, n):
    buf = b''
    while len(buf) < n:
        buf += ser.read(n - len(buf))
    return buf


def read_request(ser, idle):
    """Waits for a request, calling idle() while there is none."""
    buf = b''
    while not buf:
        buf = ser.read(1)
        if not buf:
            idle()
    buf += read_exact(ser, HDR.size - 1)
    while buf[:2] != b'DK':  # resync
        buf = buf[1:] + read_exact(ser, 1)
    return HDR.unpack(buf)


def respond(ser, op, status, seq, value, data=b''):
    ser.write(HDR.pack(b'kd', op, status, seq, value, 0) + data)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('disk', help='FAT12 image file or directory for B:')
    ap.add_argument('--port', help='serial port (default: auto-detect if06)')
    ap.add_argument('--readonly', action='store_true')
    ap.add_argument('--free', type=float, default=8,
                    help='free space in MB for a directory (default: 8)')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()

    if os.path.isdir(args.disk):
        d = DirDrive(args.disk, args.readonly, int(args.free * 1024 * 1024))
    else:
        d = ImageDrive(args.disk, args.readonly)
    port = args.port or find_port()
    ser = serial.Serial(port, 115200, timeout=0.1)
    print(f'Serving {args.disk} as B: on {port}', flush=True)

    while True:
        _, op, drive, seq, off, length = read_request(ser, d.idle)
        opc = chr(op)
        payload = read_exact(ser, length) if opc == 'W' else b''
        if args.verbose:
            print(f'{opc} drive={drive} off={off:#x} len={length}')

        if drive != 0:
            respond(ser, op, 1, seq, 0)
        elif opc == 'R':
            data = d.read(off, length)
            if data is None:
                respond(ser, op, 1, seq, 0)
            else:
                respond(ser, op, 0, seq, length, data)
        elif opc == 'W':
            respond(ser, op, 0 if d.write(off, payload) else 1, seq, 0)
        elif opc == 'C':
            respond(ser, op, 0, seq, d.media_check())
        else:
            respond(ser, op, 1, seq, 0)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
