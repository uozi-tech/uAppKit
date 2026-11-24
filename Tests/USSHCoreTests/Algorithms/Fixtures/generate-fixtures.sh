#!/bin/bash
# 重新生成 RSAFixtures.swift 与 DHFixtures.swift。
#
# 用真实的 OpenSSH / OpenSSL 产出密钥与签名，冻结成 Swift 常量，测试时不依赖这些工具：
# - ssh-keygen 生成 1024 / 2048 / 3072 / 4096 位 RSA 密钥（OpenSSH 格式）与 .pub（ssh-rsa blob）；
# - ssh-keygen -Y sign 产出 SSHSIG（里面是 OpenSSH 自己编码的 rsa-sha2-512 签名 blob）；
# - 同一把钥转成 PEM 后，openssl 取出全部分量，并用 dgst 产出 SHA-1 / SHA-256 / SHA-512 的 PKCS#1 v1.5 签名；
# - python3 按 RFC 4253 §8 独立算一遍 DH 的 e、f、K 与交换哈希 H（自己的 string / mpint 编码）。
#
# 用法：bash Tests/USSHCoreTests/Algorithms/Fixtures/generate-fixtures.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OPENSSL="${OPENSSL:-openssl}"

printf 'uTerm USSHCore RSA fixture message\n' > "$WORK/message"

for bits in 1024 2048 3072 4096; do
    ssh-keygen -q -t rsa -b "$bits" -N "" -C "fixture-$bits" -f "$WORK/rsa$bits"
    cp "$WORK/rsa$bits" "$WORK/rsa$bits.pem"
    ssh-keygen -q -p -m PEM -N "" -P "" -f "$WORK/rsa$bits.pem" > /dev/null
    "$OPENSSL" rsa -in "$WORK/rsa$bits.pem" -text -noout > "$WORK/rsa$bits.txt" 2> /dev/null
    ssh-keygen -q -Y sign -f "$WORK/rsa$bits" -n file "$WORK/message" > /dev/null 2>&1
    mv "$WORK/message.sig" "$WORK/rsa$bits.sshsig"
    for digest in sha1 sha256 sha512; do
        "$OPENSSL" dgst -"$digest" -sign "$WORK/rsa$bits.pem" -out "$WORK/rsa$bits.$digest.sig" "$WORK/message"
    done
done

python3 - "$WORK" "$HERE" <<'PY'
import base64, hashlib, os, re, secrets, sys

work, here = sys.argv[1], sys.argv[2]

def swift_hex(b):
    h = b.hex()
    lines = [h[i:i + 96] for i in range(0, len(h), 96)] or [""]
    return '"""\n' + "\n".join("        " + l for l in lines) + '\n        """'

def components(text):
    fields = {}
    current = None
    for line in text.splitlines():
        m = re.match(r"^(\w+):\s*(.*)$", line)
        if m:
            current = m.group(1)
            fields[current] = m.group(2)
            continue
        if current and re.match(r"^\s+[0-9a-f:]+$", line):
            fields[current] += line.strip()
    def num(name):
        v = fields[name]
        if "(" in v:
            v = v.split("(")[0]
        v = v.strip()
        if v.startswith("0x"):
            v = v[2:]
        if ":" in v or not v.isdigit():
            v = v.replace(":", "")
            return bytes.fromhex(v).lstrip(b"\0")
        n = int(v)
        return n.to_bytes((n.bit_length() + 7) // 8, "big")
    return {k: num(k) for k in ["modulus", "publicExponent", "privateExponent", "prime1", "prime2", "exponent1", "exponent2", "coefficient"]}

message = open(os.path.join(work, "message"), "rb").read()
out = []
out.append("// 由 generate-fixtures.sh 生成，别手改。\n")
out.append("enum RSAFixtures {")
out.append("    struct Key {")
out.append("        let bits: Int")
out.append("        let publicKeyBlob: String")
out.append("        let modulus: String")
out.append("        let publicExponent: String")
out.append("        let privateExponent: String")
out.append("        let prime1: String")
out.append("        let prime2: String")
out.append("        let exponent1: String")
out.append("        let exponent2: String")
out.append("        let coefficient: String")
out.append("        let pkcs1PEM: String")
out.append("        /// ssh-keygen -Y sign 的 SSHSIG（去掉 armor 后的二进制）。")
out.append("        let sshsig: String")
out.append("        let sha1Signature: String")
out.append("        let sha256Signature: String")
out.append("        let sha512Signature: String")
out.append("    }\n")
out.append("    static let message = " + swift_hex(message) + "\n")
out.append("    static let keys: [Key] = [")
for bits in [1024, 2048, 3072, 4096]:
    base = os.path.join(work, f"rsa{bits}")
    comp = components(open(base + ".txt").read())
    pub = base64.b64decode(open(base + ".pub").read().split()[1])
    pem = open(base + ".pem").read().strip()
    armored = open(base + ".sshsig").read()
    sshsig = base64.b64decode("".join(l for l in armored.splitlines() if not l.startswith("-----")))
    sigs = {d: open(f"{base}.{d}.sig", "rb").read() for d in ["sha1", "sha256", "sha512"]}
    out.append("        Key(")
    out.append(f"            bits: {bits},")
    out.append(f"            publicKeyBlob: {swift_hex(pub)},")
    for name in ["modulus", "publicExponent", "privateExponent", "prime1", "prime2", "exponent1", "exponent2", "coefficient"]:
        out.append(f"            {name}: {swift_hex(comp[name])},")
    out.append('            pkcs1PEM: """\n' + "\n".join("            " + l for l in pem.splitlines()) + '\n            """,')
    out.append(f"            sshsig: {swift_hex(sshsig)},")
    out.append(f"            sha1Signature: {swift_hex(sigs['sha1'])},")
    out.append(f"            sha256Signature: {swift_hex(sigs['sha256'])},")
    out.append(f"            sha512Signature: {swift_hex(sigs['sha512'])}")
    out.append("        ),")
out.append("    ]")
out.append("}")
open(os.path.join(here, "RSAFixtures.swift"), "w").write("\n".join(out) + "\n")

# ---- DH ----
P14 = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
    "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
    "15728E5A8AACAA68FFFFFFFFFFFFFFFF", 16)

def pi_fixed(bits):
    guard = 64
    one = 1 << (bits + guard)
    def arctan_inv(x):
        s = 0; t = one // x; n = 1; sign = 1; x2 = x * x
        while t:
            s += sign * (t // n); t //= x2; n += 2; sign = -sign
        return s
    return (16 * arctan_inv(5) - 4 * arctan_inv(239)) >> guard

# 这里按 RFC 3526 的公式现算（与源码里写死的十六进制常量互为核对）。
assert P14 == 2**2048 - 2**1984 - 1 + 2**64 * (pi_fixed(1918) + 124476)
P16 = 2**4096 - 2**4032 - 1 + 2**64 * (pi_fixed(3966) + 240904)

def ssh_string(b):
    return len(b).to_bytes(4, "big") + b

def ssh_mpint(n):
    if n == 0:
        return ssh_string(b"")
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    if b[0] & 0x80:
        b = b"\0" + b
    return ssh_string(b)

def to_bytes(n):
    return n.to_bytes((n.bit_length() + 7) // 8, "big")

host_key = base64.b64decode(open(os.path.join(work, "rsa2048.pub")).read().split()[1])
vc = b"SSH-2.0-OpenSSH_9.9"
vs = b"SSH-2.0-uTermFixtureServer_1.0"
ic = bytes([20]) + secrets.token_bytes(16) + ssh_string(b"diffie-hellman-group14-sha256,diffie-hellman-group16-sha512") + secrets.token_bytes(40)
is_ = bytes([20]) + secrets.token_bytes(16) + ssh_string(b"diffie-hellman-group16-sha512,diffie-hellman-group14-sha256") + secrets.token_bytes(37)

dh = []
dh.append("// 由 generate-fixtures.sh 生成，别手改。\n")
dh.append("enum DHFixtures {")
dh.append("    struct Vector {")
dh.append("        let algorithm: String")
dh.append("        let clientExponent: String")
dh.append("        let serverExponent: String")
dh.append("        let e: String")
dh.append("        let f: String")
dh.append("        /// K 的 mpint 编码（含长度前缀）。")
dh.append("        let sharedSecretMPInt: String")
dh.append("        let exchangeHash: String")
dh.append("        /// 用 RFC 4253 §7.2 推出的 64 字节「C」密钥（session_id = H），覆盖长度扩展。")
dh.append("        let derivedKeyC64: String")
dh.append("    }\n")
dh.append(f"    static let clientVersion = {swift_hex(vc)}")
dh.append(f"    static let serverVersion = {swift_hex(vs)}")
dh.append(f"    static let clientKexInit = {swift_hex(ic)}")
dh.append(f"    static let serverKexInit = {swift_hex(is_)}")
dh.append(f"    static let serverHostKey = {swift_hex(host_key)}\n")
dh.append("    static let vectors: [Vector] = [")
for name, p, h in [("diffie-hellman-group14-sha256", P14, hashlib.sha256),
                   ("diffie-hellman-group16-sha512", P16, hashlib.sha512),
                   ("diffie-hellman-group14-sha1", P14, hashlib.sha1)]:
    x = secrets.randbits(512) | (1 << 511)
    y = secrets.randbits(512) | (1 << 511)
    e = pow(2, x, p); f = pow(2, y, p); k = pow(f, x, p)
    assert k == pow(e, y, p)
    kmp = ssh_mpint(k)
    H = h(ssh_string(vc) + ssh_string(vs) + ssh_string(ic) + ssh_string(is_) + ssh_string(host_key)
          + ssh_mpint(e) + ssh_mpint(f) + kmp).digest()
    key = h(kmp + H + b"C" + H).digest()
    while len(key) < 64:
        key += h(kmp + H + key).digest()
    dh.append("        Vector(")
    dh.append(f'            algorithm: "{name}",')
    dh.append(f"            clientExponent: {swift_hex(to_bytes(x))},")
    dh.append(f"            serverExponent: {swift_hex(to_bytes(y))},")
    dh.append(f"            e: {swift_hex(to_bytes(e))},")
    dh.append(f"            f: {swift_hex(to_bytes(f))},")
    dh.append(f"            sharedSecretMPInt: {swift_hex(kmp)},")
    dh.append(f"            exchangeHash: {swift_hex(H)},")
    dh.append(f"            derivedKeyC64: {swift_hex(key[:64])}")
    dh.append("        ),")
dh.append("    ]")
dh.append("}")
open(os.path.join(here, "DHFixtures.swift"), "w").write("\n".join(dh) + "\n")
PY
echo "已写入 $HERE/RSAFixtures.swift 与 $HERE/DHFixtures.swift"
