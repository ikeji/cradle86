# cradle86

Raspberry Pi Pico (RP2040) で実機の **NEC V30 (μPD70116)** または **80C88 (8088)** CPU を 3.3V 駆動し、外部 RAM チップなしで **MS-DOS 2.11 ([HIDOS](https://github.com/ikeji/HIDOS))** を動かすシングルボードコンピュータです。

RP2040 の Core 1 が CPU のアドレス／データバスを直接エミュレートし、内蔵 SRAM（208 KB）をメインメモリとして提供します。Core 0 は USB 4 ポート CDC（モニタ・DOS コンソール・AUX・仮想ディスク B:）を担当します。

## Web 端末（GitHub Pages）

ブラウザから直接接続できる端末を用意しています（アプリ不要・HTTPS 動作）：

- **https://ikeji.github.io/cradle86/**（[docs/index.html](docs/index.html)）
  - **Android Chrome（WebUSB）**: 「USB接続 (3ポート同時)」1 回で Monitor + DOS コンソール + ブラウザ内仮想ディスク B: を同時接続
  - **PC Chrome / Edge（Web Serial）**: 各ポートを個別接続
  - `xterm.js` による 80×25 フル ANSI / Shift_JIS 表示、ワンタップデモボタン（`DOS起動` / `SANITY` / `MANDEL` / `LIFE` / `VI`）、仮想ディスク B: の読込・保存・初期化・`LHA+LSIC` プリセット対応

## 主な特徴

- **同一基板で V30 / 80C88 両対応（自動判別）**
  - リセット直後の最初の T1 でデータバスを Hi-Z のまま Pin 28（V30=`M/IO#` HIGH / 80C88=`IO/M#` LOW）を読んで自動判別し、バス衝突ゼロで 16-bit / 8-bit エンジンと既定クロックを自動切替します。
- **GPIO クロックエンジン（`monitor/gpio_hidos.S`）**
  - Core 1 がクロックを生成しながら T1〜T4 を処理する方式。
  - 3.3V 実測: V30 約 **9.6 MHz**（既定 `c g 72 52 40`）、80C88 約 **7.2 MHz**（既定 `c g 80 60 60`、上限 8.7 MHz）。
- **ROM ディスク（A:）収録ソフト**
  - MS-DOS 2.11 標準コマンド（`COMMAND.COM`, `DEBUG.COM`, `CHKDSK.COM`, `EDLIN.COM` 等）
  - 開発ツール（`MASM.EXE`, `LINK.EXE`）
  - 検証・デモ・ツール（`SANITY.COM`（V30/V20/8086/8088 判別付きセルフテスト）、`VI.EXE`、`SHA1SUM.EXE`、`CRC32SUM.EXE`、`MANDEL.COM`、`LIFE.COM`）

## ディレクトリ構成

| パス | 内容 |
| :--- | :--- |
| `monitor/` | RP2040 ファームウェア（`main.cpp`, `gpio_hidos.S`）、仮想ディスクサーバ（`disk_server.py`）、`cradle.sh` |
| `embedded-hidos/` | フラッシュ内蔵の `boot.img` / `disk.img` ビルド、`SANITY.COM` / `MANDEL.COM` / `LIFE.COM` |
| `docs/` | GitHub Pages 用 Web 端末（`index.html`）および B: プリセットイメージ |
| `cradle86pcb/` | KiCad 回路図・基板データ |
| `case/` | 3D プリント用ケース（JSCAD） |
| `HIDOS/`, `tiny-vi-clone/`, `sha1sum/` | サブモジュール |

## ビルド・書き込み

```bash
# ファームウェアのビルド（boot.img / disk.img も自動生成）
make -C monitor build/v30_control.uf2

# BOOTSEL モードで接続した Pico へ書き込み
make -C monitor flash

# tmux で DOS コンソール・モニタ・B: ディスクサーバをまとめて起動
./monitor/cradle.sh
```

## ドキュメント

- [monitor/project.md](monitor/project.md) — ピン配置・回路構成・モニタコマンド一覧
- [monitor/gpio_clock.md](monitor/gpio_clock.md) — GPIO クロックエンジンの設計と V30 / 80C88 実測タイミング
- [monitor/memaccess.md](monitor/memaccess.md) — バスアクセス手順メモ
