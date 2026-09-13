#!/usr/bin/env python3
"""Generate BoringSSL sources without XChaCha/HChaCha, preserving pinned originals."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
units = {
    'crypto/cipher_extra/e_chacha20poly1305.c': [
        'static int aead_xchacha20_poly1305_seal_scatter(',
        'static int aead_xchacha20_poly1305_open_gather(',
        'static const EVP_AEAD aead_xchacha20_poly1305 =',
        'const EVP_AEAD *EVP_aead_xchacha20_poly1305(',
    ],
    'crypto/chacha/chacha.c': ['void CRYPTO_hchacha20('],
}
for relative, declarations in units.items():
    source = root / relative
    text = source.read_text()
    for declaration in declarations:
        assert text.count(declaration) == 1, f'Upstream changed: {declaration}'
        start = text.index(declaration)
        opening = text.index('{', start)
        depth, end = 1, opening + 1
        while depth:
            depth += (text[end] == '{') - (text[end] == '}')
            end += 1
        if text[end:end + 1] == ';':
            end += 1
        text = text[:start] + text[end:]
    assert 'xchacha' not in text.lower() and 'hchacha' not in text.lower()
    # Preserve relative include resolution while compiling outside the source tree.
    import re
    text = re.sub(r'#include "([^"]+)"', lambda m: '#include "' + str((source.parent / m[1]).resolve()) + '"', text)
    target = output / source.name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists() or target.read_text() != text:
        target.write_text(text)
