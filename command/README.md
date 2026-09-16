# commandディレクトリ内のファイルについて

ここにあるのは、CP/M-80のコマンドファイル FDISK.COM, FDFORMAT.COM, HDFORMAT.COM を生成するためのソースコードです。i8080のアセンブリコードで記述してあり、asm8080などでアセンブルできます。アセンブルして出来たbinファイルを、前述のCOMファイルにリネームして使います。

```
asm8080 FDISK80.ASM
mv FDISK80.bin FDISK.COM
```

## *.INCファイルについて

FDFORMAT80.ASMのアセンブル時にはFDIPL80.INC、HDFORMAT80.ASMのアセンブル時にはMASTERIPL80.INC、HDIPL80.INCというファイルをインクルードします。FDIPL80.INCはフロッピー用のIPLコード、HDIPL80.INCはHDD区画用のIPLコードです。MASTERIPL80.INCは、HDDのマスターIPLコードです。

*.INCファイルは次のコマンドで生成できます。

```
nasm -f bin fdipl80.asm -o FDIPL80.BIN
nasm -f bin hdipl80.asm -o HDIPL80.BIN
nasm -f bin master-ipl.asm -o MASTERIPL80.BIN

python3 bin2inc.py FDIPL80.BIN FDIPL80.INC --label FDIPL80
python3 bin2inc.py HDIPL80.BIN HDIPL80.INC --label HDIPL80
python3 bin2inc.py MASTERIPL80.BIN MASTERIPL80.INC --label MASTERIPL80
```
