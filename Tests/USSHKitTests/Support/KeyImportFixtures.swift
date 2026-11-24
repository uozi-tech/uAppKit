// USSHKit 私钥导入测试夹具 —— 仅供单元测试，勿用于任何真实主机。
//
// 生成方式（同一把 RSA 2048，两种落盘格式；第三把带口令）：
//   ssh-keygen -t rsa -b 2048 -N "" -m PEM -C usshkit-test -f rsa_pem
//   cp rsa_pem rsa_openssh && ssh-keygen -p -N "" -P "" -f rsa_openssh
//   ssh-keygen -t rsa -b 2048 -N "" -C usshkit-test -f rsa_enc
//   ssh-keygen -p -N "$passphrase" -P "" -f rsa_enc
// 另有一把 ed25519（用于"非 RSA 容器应被拒"）：
//   ssh-keygen -t ed25519 -N "" -C usshkit-test -f ed_openssh
// 两把 ECDSA P-256（明文 / 带口令，覆盖容器的两条分支）：
//   ssh-keygen -t ecdsa -b 256 -N "" -C usshkit-test -f ec256_openssh
//   ssh-keygen -t ecdsa -b 256 -N "" -C usshkit-test -f ec256_enc
//   ssh-keygen -p -N "$passphrase" -P "" -f ec256_enc
nonisolated enum KeyImportFixtures {
    static let passphrase = "testpass123"

    static let rsaOpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
    NhAAAAAwEAAQAAAQEA1c8plntnm+lKaW6ZzEk1ryXp5q+9wvhaW4JNma1Q3QXT7h9L1bko
    GPIqaH051Os2gdMrQK6tvolcY8OiIYQmANSireejKPKjZO9EkRxCWMzVHmR2d/BoBHS/aF
    e9G+9yFwi8eI352R493cQjFXrBGP6GPDN/rc18yPSXN2Q8sGBmmQQ5xDgAFqBQcHXmZyNc
    ThvEek6KjzpjFwTlZB0dMov4U6/MEjn1b4GaDgMXpIACnU25SnAcP7lyym0D7LllfbnfRH
    rjNLfze5TIYV+DeHgV0P/X//P6fIe1418OPKhiDawTSdC+52YsWG1OjiSoFfNvQaGNfk6B
    ZvP21d0HlwAAA7jqcKTT6nCk0wAAAAdzc2gtcnNhAAABAQDVzymWe2eb6UppbpnMSTWvJe
    nmr73C+Fpbgk2ZrVDdBdPuH0vVuSgY8ipofTnU6zaB0ytArq2+iVxjw6IhhCYA1KKt56Mo
    8qNk70SRHEJYzNUeZHZ38GgEdL9oV70b73IXCLx4jfnZHj3dxCMVesEY/oY8M3+tzXzI9J
    c3ZDywYGaZBDnEOAAWoFBwdeZnI1xOG8R6ToqPOmMXBOVkHR0yi/hTr8wSOfVvgZoOAxek
    gAKdTblKcBw/uXLKbQPsuWV9ud9EeuM0t/N7lMhhX4N4eBXQ/9f/8/p8h7XjXw48qGINrB
    NJ0L7nZixYbU6OJKgV829BoY1+ToFm8/bV3QeXAAAAAwEAAQAAAQBz2uV2HThvS2J+7ud3
    wtPMLIcp8WCqHVkY7OqPs1J18Yp9JYg6LzKDEfXY2MJVlX7bqkltqzmKXXQquv9Hmgvdt1
    rPUQ0gSxouv1gwKVfqNlPlPBrVsvcqMvjk2WYnlQAFaz51NLmF5NUxLe603Od1W7XxORae
    XxKW8bJe2XnpN9V4Ft+ewXRtwoF1F+8ZK5DquQr2Ek23hB6e+46zqaR+DxRyHVoIgP+b/5
    kxVmgrhIaYXD9quf309DOBxJH0L+jtMjQ3Vbk7S/1+7/iEfbvjTFGS1g1sBhqu5Iur8ucT
    RIVexU1+2+7+HxDhAHJkWUuey3o9JkLi7LbTqSFky/mBAAAAgEMSGsdN6I/Q0BjhD7CQiC
    9TbzYUEcn/qoseZdurQO/Hf1SU/cKp+9fmBzIyuHQu3ykDDV47Fk8un8j1SoRbUr0zaHZZ
    X8RoV8CthNN8n4EUzWhn8Apg+1EwFy7SdL53yJeFPyggaw335yHPTwYumodC4GZYFfn7BG
    AezNcWP3tgAAAAgQD2xKLlfiSfT+TRUJ9EP7VdTb5/Wv2vUaBdEVOpv9r8YsSrt8Y6kBV4
    Y7jBg9izCZX3wxAVS1Xk7LcVsIO7IEm/exwr4NACDtyl8kHxAgtdpnKkOPbUicTlWW/v6X
    TlgZTTJZ+HNtcNrDxz+Yu4NQVO7bfuzwlT+19Oxz5bSGeQGQAAAIEA3c7ew9NrL/4ameLt
    nSDzi9hxLt4q8IILIQwivtkVB1LHzNwk/zahOrBTGkcKM6/B1KofewAD1cDMcDRwcAJYQU
    fMWJrJYheTCSz0F6Saj5S3Q886jP29/++ZObe4FEVYPUdb/I8+zBc/huODngqbKtjTkmDx
    nShk8tZhqQ/8iy8AAAAAAQID
    -----END OPENSSH PRIVATE KEY-----

    """

    static let rsaPKCS1 = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEA1c8plntnm+lKaW6ZzEk1ryXp5q+9wvhaW4JNma1Q3QXT7h9L
    1bkoGPIqaH051Os2gdMrQK6tvolcY8OiIYQmANSireejKPKjZO9EkRxCWMzVHmR2
    d/BoBHS/aFe9G+9yFwi8eI352R493cQjFXrBGP6GPDN/rc18yPSXN2Q8sGBmmQQ5
    xDgAFqBQcHXmZyNcThvEek6KjzpjFwTlZB0dMov4U6/MEjn1b4GaDgMXpIACnU25
    SnAcP7lyym0D7LllfbnfRHrjNLfze5TIYV+DeHgV0P/X//P6fIe1418OPKhiDawT
    SdC+52YsWG1OjiSoFfNvQaGNfk6BZvP21d0HlwIDAQABAoIBAHPa5XYdOG9LYn7u
    53fC08wshynxYKodWRjs6o+zUnXxin0liDovMoMR9djYwlWVftuqSW2rOYpddCq6
    /0eaC923Ws9RDSBLGi6/WDApV+o2U+U8GtWy9yoy+OTZZieVAAVrPnU0uYXk1TEt
    7rTc53VbtfE5Fp5fEpbxsl7Zeek31XgW357BdG3CgXUX7xkrkOq5CvYSTbeEHp77
    jrOppH4PFHIdWgiA/5v/mTFWaCuEhphcP2q5/fT0M4HEkfQv6O0yNDdVuTtL/X7v
    +IR9u+NMUZLWDWwGGq7ki6vy5xNEhV7FTX7b7v4fEOEAcmRZS57Lej0mQuLsttOp
    IWTL+YECgYEA9sSi5X4kn0/k0VCfRD+1XU2+f1r9r1GgXRFTqb/a/GLEq7fGOpAV
    eGO4wYPYswmV98MQFUtV5Oy3FbCDuyBJv3scK+DQAg7cpfJB8QILXaZypDj21InE
    5Vlv7+l05YGU0yWfhzbXDaw8c/mLuDUFTu237s8JU/tfTsc+W0hnkBkCgYEA3c7e
    w9NrL/4ameLtnSDzi9hxLt4q8IILIQwivtkVB1LHzNwk/zahOrBTGkcKM6/B1Kof
    ewAD1cDMcDRwcAJYQUfMWJrJYheTCSz0F6Saj5S3Q886jP29/++ZObe4FEVYPUdb
    /I8+zBc/huODngqbKtjTkmDxnShk8tZhqQ/8iy8CgYEAiG/CDRcIkpjuz5g+5tI+
    qZ7Rg8LAXo3IF4z77+/m2QKW8MaEMF73r/+a6EvIpXzYUQuludBUZmVG+RQGUZER
    lXAw7EW5XFnxP0NJmEJkHFxqKEhimLKvjYs8q64tdrOFoJS9tlno32NqbUj9KlUO
    YUxoFP6djrR+RqU84eWPdQkCgYEA1XSIwpGKPIRgWymcm7MjTbh8q6rYTd4IEcSZ
    B2rnpsWOS+KrpAORw2X+g3JMKhOBCESzyO3pwuIom+6LKe/HuQL8b2R+Wuzu7kyZ
    lssshvKKLzKVWSuzlkKhBX99IdzeHxK2PmYn+8Z/tzLp7cStMN27NcofmqtOArg3
    AbjFw7cCgYBDEhrHTeiP0NAY4Q+wkIgvU282FBHJ/6qLHmXbq0Dvx39UlP3CqfvX
    5gcyMrh0Lt8pAw1eOxZPLp/I9UqEW1K9M2h2WV/EaFfArYTTfJ+BFM1oZ/AKYPtR
    MBcu0nS+d8iXhT8oIGsN9+chz08GLpqHQuBmWBX5+wRgHszXFj97YA==
    -----END RSA PRIVATE KEY-----

    """

    static let rsaOpenSSHEnc = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDHvec11p
    y9Icm6haFa+rmGAAAAGAAAAAEAAAEXAAAAB3NzaC1yc2EAAAADAQABAAABAQCqelEK8rnA
    E6KskwfagfvSjf4lXO7xMDg4VN3GHQyU7w2BTrJDMEdTlx/ZOMLfKK8P2C3RgdBRj5hGj/
    Pj2FM8aXyWGbxMly2eb26hop7u9X3iuCMq1O3ZCAISip8jVP+uhn4nm7FsaaZwBCWwFjrH
    le6uAHNE3vhLD+itMDHLMjzdJiosLsB5zr9iiev3nUd6AhC7vuQAsKJtsGuhzw80nsKt0h
    nM2ftOkQUpksaZkh8eXrTK2x/EeiSzaE0rAErzuG9oChhz6BOOCI08TCPYWQar3OCbbQR9
    Ffa8AiZIqFmN/JvzdyO1SBkvmQgZzqWIKsI1ozSX9INGgb7A2m/fAAAD0MDV3maCJtw/2f
    IIlR+gEu3++XzfO671UHQGiKpTEsyPr2QOuevRw17vclUCX614/xPB7ZKg/Mma7oqgiTIA
    BtSaOKA45vVH+5QzJ6RFjwVpIbKFoAxJX6J33yssl+AJyRZiijuYSf2je/jN4Bjb90z+xc
    GXFw5wY+KUYTU27dBqnEbHF2M5Qi5DVKl793dPspmISaKzcHRwU+Bsc6FGwe8dvtDr7CX3
    0ssMLFBhqZLIJizC84Zm6G3HnZ9WeA2y03lDH1BfShTh4OY5W2u5TzDS+xaNycDpe05LiQ
    4XMAekJJL4yvS60SEfChbihQCitKysvPEM6eSSj0IASlbl7LluarX9riS665EeHwJxoqFO
    lb4eRaf+yXkfeZohRKtyCMwfXDAtuSx9CzE0UHOgogkaAN+Q5nmecvYFyt64myIcB7j5lW
    CFJoFhZpmhWAgGlOEKtJAQQX2WcreMRg0z6XjZV7mi8SmIybFRx0UgneYLjwfVbzO40vRa
    NoZ2DgzGi1NxGtN49XzQ0P0RZstubR8xVnkYx2f45xCknGDsP7Uugv9ktDi3fcprIj9FGG
    oYH38+0kF1XnoHShXGY26nVV7ggJOg3zcwxDGs69DkpOxXGWb6RXZKsCDWkdFhRMFc6p3U
    H2IdJ7FwDM8X8Ei7792OQNAFldkVoCji1He/SUCuPMubNZBBDzeDqXo3IhTIOeuwOyCd3r
    FbFz3MEnLKh6FRH3Yv1f2vPfBEWUHJ+iK9S0qUBBed62Nw5g3wND23p9BucISbMTiHlbXy
    WymRF0v730+zu8uSxXpE7JBjKmqcjC1WQONrWvjhf6Swzx0Rtg6mxe+PvZLj4h60mu4/7F
    UGBGBqsblWBX75U0NI35CJfi0KEFYNY4whHImfqqzT4BGA2v2FsEM6Hd7Z76JOYN81PhAm
    po30QIxAqemuKUBBmI5p4EhzJvaoLcC9Mz3xb2NRk1K8WfeVvDN3wV06bD6BcchsnlWVIU
    k2dvKGTmlRoAhQtXgyWCRMkYSu7izPMunObQfc3tCFKtAGVf/l2VO0isG+ysf9QnX82vUr
    3LsWILZPbySSXe4SFFBjj8+tc8dHBiNiTJnpjTiBmThFVlB3NOFqG6vm03jjDnlZ/xYZ6J
    UsON+9OdIIYSO8FL3PyhocYn+pNbeRGrZmW3sFwpdfjNZDz6FxZllyZzK9Y53CfbPod5d1
    fyXjcY8m4zmVpYkSNEfq4vf/0flKCkCRU/fkStnvCR45LCXvnDYQdX00DRyklYx2R3hG+J
    Ly7q0RqnKOwUXdZDCphHVuCW84Xhg=
    -----END OPENSSH PRIVATE KEY-----

    """

    static let ed25519OpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACChAMt2fn5YYdN8frKhcQD8snRTUwyzDLny/ITk2zaaVAAAAJDY1VCC2NVQ
    ggAAAAtzc2gtZWQyNTUxOQAAACChAMt2fn5YYdN8frKhcQD8snRTUwyzDLny/ITk2zaaVA
    AAAEDDL4uqNyvPe34bQoIohLVIo0gqSr2akdIgFXR26HvEqaEAy3Z+flhh03x+sqFxAPyy
    dFNTDLMMufL8hOTbNppUAAAADHVzc2hraXQtdGVzdAE=
    -----END OPENSSH PRIVATE KEY-----
    """

    static let ecP256OpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQTvTOewURQbJnWBgg0cXrE2cggRAXeL
    de9V38bVazhSe8sAWqWRJaxvy/1mfrly1Y/2iejlFtovCxYGFr+Y2dVVAAAAqFEI2I1RCN
    iNAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBO9M57BRFBsmdYGC
    DRxesTZyCBEBd4t171XfxtVrOFJ7ywBapZElrG/L/WZ+uXLVj/aJ6OUW2i8LFgYWv5jZ1V
    UAAAAhAIp5riQ6GSrCr8q0YkcSVoVtR03qnokc1W5/dS0Yb2+jAAAADHVzc2hraXQtdGVz
    dAECAw==
    -----END OPENSSH PRIVATE KEY-----
    """

    static let ecP256OpenSSHEnc = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDJ3LTh2X
    l2JVrOFjtWJaMmAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
    dHAyNTYAAABBBJL6DwATRvSVE6UGV/kiV0Edh1Iy4vfGnnMyr1DitSg+p35XOrU5MIe7Es
    dvGxzv2I+7QxeBfS3OWjxdaFoJ/ooAAACwM7L8TB0PMIyqB12+rzY1onRS/yh4EI+QhUOm
    JPRrpYqO5iTm1QzCy3DsfRD7PEz3i8Qq/J05R8zpNAeJ0d1EDOGoSsaNTZBDMIRbri8tD0
    Z9uryLHgfzV/fxwh+UIvskZkUgS7N1ZN2EGfwxlFpxl6u2MoGGl5OtBl9zoLbXPD5X5Kdo
    i5mpmENnxYYT+3KKfqh+yyhvKnNTCp0KSe/ETaNiN80oJ4oY3PQTTTh7f4w=
    -----END OPENSSH PRIVATE KEY-----
    """

}
