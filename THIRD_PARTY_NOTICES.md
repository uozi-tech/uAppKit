# Third-party notices

## Lucide

`UIconGlyph.fileUp` / `.fileDown`（及其 `Filled` 实心版）的路径取自 Lucide 图标
`file-up` / `file-down`（lucide-static v1.73.0）。实心版为本仓库在其路径上派生。

https://lucide.dev · https://github.com/lucide-icons/lucide

```
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

The following Lucide icons are derived from the Feather project:

airplay, alert-circle, alert-octagon, alert-triangle, aperture, arrow-down-circle, arrow-down-left, arrow-down-right, arrow-down, arrow-left-circle, arrow-left, arrow-right-circle, arrow-right, arrow-up-circle, arrow-up-left, arrow-up-right, arrow-up, at-sign, calendar, cast, check, chevron-down, chevron-left, chevron-right, chevron-up, chevrons-down, chevrons-left, chevrons-right, chevrons-up, circle, clipboard, clock, code, columns, command, compass, corner-down-left, corner-down-right, corner-left-down, corner-left-up, corner-right-down, corner-right-up, corner-up-left, corner-up-right, crosshair, database, divide-circle, divide-square, dollar-sign, download, external-link, feather, frown, hash, headphones, help-circle, info, italic, key, layout, life-buoy, link-2, link, loader, lock, log-in, log-out, maximize, meh, minimize, minimize-2, minus-circle, minus-square, minus, monitor, moon, more-horizontal, more-vertical, move, music, navigation-2, navigation, octagon, pause-circle, percent, plus-circle, plus-square, plus, power, radio, rss, search, server, share, shopping-bag, sidebar, smartphone, smile, square, table-2, tablet, target, terminal, trash-2, trash, triangle, tv, type, upload, x-circle, x-octagon, x-square, x, zoom-in, zoom-out

The MIT License (MIT) (for the icons listed above)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## bcrypt_pbkdf（OpenBSD）

`Sources/CBcryptPBKDF` 是 OpenBSD 的 `bcrypt_pbkdf` 与 Blowfish（解密带口令的 OpenSSH 私钥容器用）。
`bcrypt.c` 与 `blf.c` / `blf.h` 头部保留了原许可声明（Niels Provos、Ted Unangst 的 ISC / BSD 许可）；
`bcrypt-kdf.c` 对应 OpenBSD 的 `bcrypt_pbkdf.c`（Ted Unangst，ISC 许可），我们拿到的副本没带文件头。

这份代码是经 [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1（`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`）
拿到的：Citadel 把它作为 C target `CCitadelBcrypt` 随包带着，给符号加了前缀、把 SHA-512 改成由调用方注入。
2026-11 起 Citadel 不再编进本包，这份 C 代码改名为 `CBcryptPBKDF` 由我们自己维护（符号前缀改成 `uappkit_`，
另加一行 `#undef BCRYPT_WORDS` 消掉宏重定义的警告；`uappkit_bcrypt_pbkdf` 返回前把栈上的 `sha2pass` / `sha2salt` 与
`countsalt` 清零——原版只清 `out` / `tmpout`）。Citadel 那部分改动的许可如下。

```
MIT License

Copyright (c) 2022 Orlandos

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## swift-nio-ssh

`Sources/NIOSSH` 与 `Tests/NIOSSHTests` 取自 [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) 0.15.2，带本仓库的补丁（`ThirdParty/swift-nio-ssh/`，被改过的文件头部有修改声明，补丁新增的文件头部写明出自 uAppKit、同样以 Apache-2.0 授权）。

Copyright (c) Apple Inc. and the SwiftNIO project authors.
Licensed under the Apache License, Version 2.0，全文见 `ThirdParty/swift-nio-ssh/LICENSE.txt`。
