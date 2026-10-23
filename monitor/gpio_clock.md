# GPIOクロックエンジンの高速化メモ

PWMクロックをやめ、Core 1 がCLKを自分で生成しながらバスを処理する `gpio_bus_run()` を高速化した時の知見。
V30の速度は平均クロック、動作可否は DOS 上の `SANITY` が全項目合格するかで判定した。

## 結果

| 構成 | V30平均クロック | SANITY |
|---|---|---|
| PWM 500kHz(作業前の既定) | 0.5MHz | 合格 |
| PWM 250kHz | — | 不合格(Divide overflow / ハング) |
| 旧GPIOエンジン(1クロックごとの状態機械 + SysTick待ち) | 1.5MHz | 合格 |
| 旧GPIOエンジン 最速設定 | 3.2MHz | 合格 |
| 新エンジン 既定 `c g 72 24 36`, Pico 250MHz | 5.5MHz | 合格 |
| 新エンジン `c g 60 12 24`, Pico 250MHz | 6.3MHz | 合格 |
| 試作版(フェーズ毎ノブ、T3/T4のlow待ち無し), Pico 250MHz | 7.3MHz | 合格(余裕無し) |
| 新エンジン `c s 400` + `c g 60 36 30` | 7.1MHz | 合格 |
| 新エンジン `c s 400` + `c g 48 36 36` | 7.0MHz | 合格 |

PWM 250kHz が落ちて 125kHz/500kHz が通る理由は未調査。

## エンジンの構造

- バスサイクル1回(T1〜T4)を直線コードに展開。1クロック毎の状態分岐とSysTick待ちが ~280ns/clock 掛かっていたのが旧エンジンのボトルネックだった。
- 待ちは `spin(n)`(`sub`/`bne` ループ、1周3 sysclk)。`c g <addr> <low> <high>` のns指定から `loops = (ns*sys_mhz/1000+2)/3` で換算。
  - `spin` の asm には `"memory"` クロバーが必須。無いと volatile な SIO 書き込みと順序が入れ替わり、パルス幅が崩れる。
  - Thumb の inline asm は divided syntax なので `subs` ではなく `sub` と書く。
- 処理は可能な限り CLK high 期間に置く(V30の最小high幅と重ねて隠す)。
  - T1 high: アドレス確定 → `map_address` → RAMから16bitワードを先読み。
  - T3 write: CLKを上げてからデータをラッチして書き込み。
- RAMは `aligned(4)` にして16bit単位でアクセス。readはワードをそのまま出し、byte選択はV30にA0/BHE#でさせる。
- 1バスサイクルあたり Pico 側の命令が 76〜110 sysclk 程度。これが現在の支配的コスト。

## V30側のタイミング制約(実測)

- **アドレス遅延**: T1の立ち下がりから ALE/アドレスが読めるまで約60ns必要(`addr` パラメータ)。これより短いと誤アドレス。
- **CLK最小幅**: low/high とも概ね 24〜36ns 以上必要。割ると暴走。
- **T3 low**: Pico 400MHz では T3 の low が短すぎて落ちた。T3 low にも `spin(low)` が必要。
- **T4 high**: 短すぎると HIDOS が 111 サイクル目で停止した。T4 にも low/high の spin を入れる。
- **データ解放**: readデータは T4 立ち下がり直後に `oe_clr` で手放すこと。T4 low の途中まで保持すると V30 と衝突し、HIDOS/IOLOG モードが起動しなくなった。
- idle(ALE待ち)ループの high 側にも `spin(high)` が必要。

## Picoのオーバークロック

- `c s <MHz>` で変更。125〜532MHz のうち `check_sys_clock_khz` が通る値のみ(350MHzは不可、300/400は可)。
- 250MHz超では `vreg_set_voltage(VREG_VOLTAGE_1_30)` → 10ms待ち → クロック変更。250MHz以下では既定電圧に戻す。
- フラッシュ(XIP)が追従できるよう boot2 を `PICO_FLASH_SPI_CLKDIV=4` でビルド(`CMakeLists.txt` の `v30_boot2`)。
- クロック変更後は `setup_gpio_clock()` / PWM の `setup_clock()` を再計算する(PWMは `clock_get_hz(clk_sys)` から分周を求め、div≥256 なら wrap を倍にする)。
- 1.30V/400MHz は RP2040 の仕様外。既定は 250MHz のまま。
- Pico を速くしても命令時間が減るだけで、V30の最小幅(上記)は ns 固定なので伸びは 6.3→7.1MHz 程度。

## ハマりどころ

- HIDOS モードでは `cycle_limit` を設定していなかったため、GPIOエンジンが1バスサイクルで停止していた。HIDOS では cycle limit を見ない(`mode != BUS_HIDOS && bus_cycles >= limit`)。
- VM_IO.SYS は初期化時に全ドライブのブートBPBを読み、失敗すると 'E' を出して停止する。B: のサーバが無い時は A: のブートセクタで応答している。

## 計測方法

- モニタで `s` → `c g ...`(必要なら `c s ...`)→ `h 2` で HIDOS 起動 → DOSコンソールで `SANITY`。
- 平均クロック = `executed_clocks / 経過時間`(`executed_clocks = idle_clocks + 4*bus_cycles`)。`c` コマンドの状態表示に出る。

## さらに速くするなら(未着手)

1. **HIDOSループのアセンブラ化**: 命令オーバーヘッドを ~45 sysclk 程度に削れる見込み。250MHzで 8MHz前後、400MHzで ~10MHz が目安(V30制約からの上限も ~10MHz)。
2. **デッドライン型の待ち**: 固定 `spin` の代わりにタイマ値で「最小幅に達するまで」待ち、その間の処理時間を待ちから差し引く。
3. NOP-JIT などの命令先読み(効果は不明)。
