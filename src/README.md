# srcディレクトリ内のファイルについて

このディレクトリにあるのは、NEC V30を搭載したPC-9801で稼働するCP/M-80のシステムイメージを作成するためのソースファイルです。

次のファイルにはi8080のアセンブリコードが記述されています。asm8080などでアセンブルしてください。

```
cpm22_pc98.asm : CP/M-80のCCP/BDOS
cbios80.asm    : CBIOS
```

アセンブル例
```
asm8080 cpm22_pc98.asm
asm8080 cbios80.asm
```

次のファイルにはi8086のアセンブリコードが記述されています。nasmなどでアセンブルしてください。

```
fdipl80.asm    : FD起動用IPL
gateway86.asm  : I/Oサービス提供用ゲートウェイ
```

アセンブル例
```
nasm -f bin fdipl80.asm -o fdipl80.bin
nasm -f bin gateway86.asm -o gateway86.bin
```

## システムイメージの作成手順

アセンブルして生成されたbinファイルは、例えば次のコマンドで連結することでシステムイメージ化できます。連結順序はこの順でなければなりません。

```
cat fdipl80.bin gateway86.bin cpm22_pc98.bin cbios80.bin > system.img
```

作成したシステムイメージは、cpmtoolsを使って次のようにFDイメージ化できます。cpmtoolsディレクトリにあるdiskdefsファイルをカレントディレクトリに置いてコマンドを実行してください。

```
mkfs.cpm -f cpm80-pc98-2hd -b system.img cpm80_2hd.img
```
