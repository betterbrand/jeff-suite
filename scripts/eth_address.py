#!/usr/bin/env python3
"""Derive an Ethereum address from a private key (hex string).

Pure Python, no dependencies. Implements secp256k1 + keccak-256.

Usage:
    PRIVATE_KEY=<hex> python3 eth_address.py
    echo <hex> | python3 eth_address.py
"""
import os
import sys
import struct

# ---------------------------------------------------------------------------
# Keccak-256 (Ethereum's hash, NOT NIST SHA-3)
# ---------------------------------------------------------------------------

def _keccak_f1600(state):
    RC = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
        0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
        0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
        0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
        0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    ROT = [
        [0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],
        [28,55,25,21,56],[27,20,39,8,14]
    ]
    MASK = (1 << 64) - 1

    for rc in RC:
        # Theta
        C = [state[x][0]^state[x][1]^state[x][2]^state[x][3]^state[x][4] for x in range(5)]
        D = [C[(x-1)%5] ^ (((C[(x+1)%5] << 1) | (C[(x+1)%5] >> 63)) & MASK) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x][y] ^= D[x]
        # Rho and Pi
        B = [[0]*5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                r = ROT[x][y]
                B[y][(2*x+3*y)%5] = ((state[x][y] << r) | (state[x][y] >> (64-r))) & MASK if r else state[x][y]
        # Chi
        for x in range(5):
            for y in range(5):
                state[x][y] = B[x][y] ^ ((~B[(x+1)%5][y] & MASK) & B[(x+2)%5][y])
        # Iota
        state[0][0] ^= rc
    return state


def keccak256(data: bytes) -> bytes:
    rate = 136  # (1600 - 256*2) / 8
    state = [[0]*5 for _ in range(5)]

    # Absorb with keccak padding (0x01, not SHA-3's 0x06)
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] |= 0x80

    for offset in range(0, len(padded), rate):
        block = padded[offset:offset+rate]
        for i in range(len(block) // 8):
            x, y = i % 5, i // 5
            state[x][y] ^= struct.unpack_from('<Q', block, i*8)[0]
        state = _keccak_f1600(state)

    # Squeeze
    out = b''
    for y in range(5):
        for x in range(5):
            out += struct.pack('<Q', state[x][y])
    return out[:32]


# ---------------------------------------------------------------------------
# secp256k1
# ---------------------------------------------------------------------------

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
A = 0
Gx = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _inv_mod(a, m):
    if a < 0:
        a = a % m
    g, x = _extended_gcd(a, m)[:2]
    return x % m


def _extended_gcd(a, b):
    if a == 0:
        return b, 0, 1
    g, x, y = _extended_gcd(b % a, a)
    return g, y - (b // a) * x, x


def _point_add(px, py, qx, qy):
    if px is None:
        return qx, qy
    if qx is None:
        return px, py
    if px == qx and py == qy:
        s = (3 * px * px + A) * _inv_mod(2 * py, P) % P
    elif px == qx:
        return None, None
    else:
        s = (qy - py) * _inv_mod(qx - px, P) % P
    rx = (s * s - px - qx) % P
    ry = (s * (px - rx) - py) % P
    return rx, ry


def _scalar_mult(k, px, py):
    rx, ry = None, None
    while k > 0:
        if k & 1:
            rx, ry = _point_add(rx, ry, px, py)
        px, py = _point_add(px, py, px, py)
        k >>= 1
    return rx, ry


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def private_key_to_address(hex_key: str) -> str:
    """Convert a hex private key to a checksummed Ethereum address."""
    key_int = int(hex_key, 16)
    pub_x, pub_y = _scalar_mult(key_int, Gx, Gy)
    pub_bytes = pub_x.to_bytes(32, "big") + pub_y.to_bytes(32, "big")

    addr_hash = keccak256(pub_bytes)
    address = addr_hash[-20:].hex()

    # EIP-55 checksum
    check_hash = keccak256(address.encode()).hex()
    checksummed = "0x"
    for i, c in enumerate(address):
        if c in "abcdef" and int(check_hash[i], 16) >= 8:
            checksummed += c.upper()
        else:
            checksummed += c

    return checksummed


if __name__ == "__main__":
    key = os.environ.get("PRIVATE_KEY", "").strip()
    if not key:
        key = sys.stdin.read().strip()
    if not key:
        print("Error: set PRIVATE_KEY env var or pipe hex key to stdin", file=sys.stderr)
        sys.exit(1)
    key = key.removeprefix("0x")
    print(private_key_to_address(key))
