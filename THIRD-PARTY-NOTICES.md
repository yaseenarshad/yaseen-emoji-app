# Third-party notices

Yaseen Emoji ships one data file, `Sources/EmojiKit/Resources/emoji.json`.
`scripts/make-emoji-data.swift` makes it from the five sources below. The app has
no outside code. The licenses of the sources follow.

The GIFs and Memes tabs also use one online service, KLIPY. See
[Online service: KLIPY](#online-service-klipy) at the end of this file.

| Source | Version | What the app uses | License |
| - | - | - | - |
| [Unicode `emoji-test.txt`](https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt) | Emoji 17.0 | the skin tone forms | Unicode-3.0 |
| [`cldr-annotations-full`](https://www.npmjs.com/package/cldr-annotations-full) (Unicode CLDR) | 48.2.0 | the English search words | Unicode-3.0 |
| [`unicode-emoji-json`](https://github.com/muan/unicode-emoji-json) | 0.9.0 | the emojis, names, groups, order, skin tone support | MIT |
| [`emojilib`](https://github.com/muan/emojilib) | 4.0.3 | community search words | MIT |
| [`gemoji`](https://github.com/github/gemoji) (`db/emoji.json`) | v4.1.0 | GitHub short names and tags | MIT |

## Unicode: `emoji-test.txt` and CLDR (Unicode-3.0)

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 2004-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0
```

The text above is the license of `cldr-annotations-full@48.2.0`. `emoji-test.txt` has the same license, with the years 1991-2026 (https://www.unicode.org/license.txt).

## unicode-emoji-json (MIT)

```
The MIT License (MIT)

Copyright (c) 2019 Mu-An Chiou

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

## emojilib (MIT)

```
The MIT License (MIT)

Copyright (c) 2014 Mu-An Chiou

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

## gemoji (MIT)

```
Copyright (c) 2019 GitHub, Inc.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
```

## Online service: KLIPY

The GIFs and Memes tabs search [KLIPY](https://klipy.com) when you add your own
KLIPY key in Settings. Without a key, the app sends nothing to KLIPY.

- **What the app sends:** the search text, the page number, and your key, to
  `https://api.klipy.com/api/v1/<key>/gifs/search`, `.../static-memes/search`,
  `.../gifs/items` and `.../static-memes/items`. It sends no user ID and asks for no ads.
- **What the app gets:** the GIFs and memes of KLIPY, from `static.klipy.com`, with
  the URLs exactly as KLIPY gives them. The app keeps them in memory only. A pick
  downloads one temp file into `~/Library/Caches/Yaseen Emoji/paste/` for the paste.
  The app deletes it after 5 minutes and at quit.
- **Your saved KLIPY items** keep only their KLIPY ID (the slug) in your list, never the file.
- **Attribution:** the search box says "Search KLIPY" when KLIPY results show, each
  KLIPY tile has a small "KLIPY" mark, and the results stay in their own section,
  "From KLIPY", in KLIPY's order. These follow the
  [attribution rules](https://docs.klipy.com/attribution.md) and the
  [integration requirements](https://docs.klipy.com/integration-requirements.md)
  of KLIPY (read on 16 Oct 2026).
- **The content** of KLIPY belongs to KLIPY and to its owners. The MIT license of
  Yaseen Emoji does not apply to it. KLIPY's own terms apply to your key.
