# ブートイメージ作成

- あるマシンのブート用メモリイメージを作って欲しいです。
- イメージのサイズは128KB(131071バイト)です。
- メモリの0x10000番地に、 VM_IO.SYS を配置してください。
- その後ろ(つまり、0x10000+sizeof(VM_IO.SYS))に、 MSDOS.SYS を配置してください。
- 0x1FFF0番地に、JMP 1000H:0000Hを配置してください。
- 0x1FFF5番地に、OUT 86H,AXを配置し、その後ろにIRETを配置してください。
- (0x86*4)番地から連続で、0x05 0x00 0xFF 0x1F を書き込んでください。
- 作成方法をMakefileに書いてください。

# ブートディスクの作成

- 次のファイルが入る仮想ディスクを作りたい。
  - VM_IO.SYS
  - MSDOS.SYS
  - COMMAND.COM
  - CHKDSK.COM
  - DEBUG.COM
- FAT12で `/sbin/mkfs.fat -S 4096 -F 12 disk.img`みたいな。

