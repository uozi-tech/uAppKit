// 私钥导入矩阵的其余夹具：与 uTerm 的 uTermTests/Support/KeyImportFixtures.swift（由同目录的
// Fixtures/generate.sh 用 ssh-keygen 与 OpenSSL 3 生成）逐字相同；ed25519OpenSSHEnc 由
//   ssh-keygen -t ed25519 -N "testpass123" -C usshkit-test
// 生成。密钥仅供单元测试，勿用于任何真实主机；口令都是 KeyImportFixtures.passphrase。
nonisolated extension KeyImportFixtures {
    static let rsaPKCS1Enc = """
    -----BEGIN RSA PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-256-CBC,655679CB798AC87C83A2326C1C525FA9
    
    xeBOigoA4skhnc5J191t5MjeGNDhlkohsoK2RW/G0cy52xBG6rfjY7+wZvXGYm/3
    2zuIWtYnAl/XC5532uyTkPWZAdx8TLt7yzSrk6UY7NWe+DNhf4jIIENwa6M5gJ1F
    nnsV0P7KUrd8LIYG0wz+Odi9onzlhU0iBRQMCBCcgSZd3Ezub3fau8UcMUCRIbd7
    oeXE63vGGUBzJeYAKxd2JKQbepP4SzoFTO9DLxWQyoxlWbZh9KzF0zfIM09GqDvs
    5ucemgryJ0ewo7TrGtye32OCftdDuVesaz6AShCXQiPDETtEk60xJCW8/24CfzXj
    zkV3B2Fl6dGdyeHj8J/h7BLbMNAc+P48M4tm7yyza2hLsszdFpYKNWMjYvVWa19W
    TtNOif5wtLaY/ETRGlEr2R9GpEzrU2yTkLCqca3+KIKhgUWREEpgBSvkBOLBVx2y
    KnmB87tX2v2hWWCfaWjpchpfqXZg5YCXp+gDfmkNtaxANHzBncaar7TwIkDi3M6j
    PBkNuCXxvFO3DIRcYPyUaji/I6zCp9JddJzUif2Z6gNT4cbjOGl9X2WbuXTvo8wD
    nUcfllten75hT4M+iCJDZQIXP81jH/YcjnNKjtE8twtdJC3LiwHstzLI5ZBWXCXs
    KrHqIwxMoDsiLszlG7YfVE8zopxWn8nUe4sVOd6ADXnuMhe2s6fBIQht2L1NQkjy
    AHNMrmXmyq6PCgB1bykOqqhd4lIRWusv+i2awwVG/EzemcNJsPaMclTToMkQDSeQ
    GxMFpY0YNBbKs3s3To2mYuBXvpo5nr08Sg+jv5UNWK2h2Ponawc6XCqbZe7OmWiO
    uw+odtQ1JMJGe4RUIVVBwblmPc9AhuVHKiGag3eCsmBKvaA/YKibBl4KzCu9NkuB
    /hzeXbvCG14pfvN3BkDln84XkqE1iIav6oMQlh5a+GlFhau5WRe/yITjS1BRJ/GN
    YtHbdQa58QOxvsK9l8PdViMvqODBpQD1/QtjdBWy/F8snvLO20PbHRfHrBFzG9pY
    MwY4r6zBIKHCqexzb03alwPR4Az2jTsfp1DZLGxEIvZjOWTH8GpO/Qrwpx8K0WcU
    Blw5BdSxOjMberLnnEWi5OhU8N4XhUcgVNIpaVs2XdlrHD1Pn1pmt4E1yB+PjryT
    LNyF69BAOyWgB1jveevaY6rphXDoHo1Ykx4/Uf9lrD4Li/mafCTHpsctSaLUlPLp
    apopYVsyi2K+7IITPSFjppqGUQ7RICfYxcf/sw2ep7ZunII4GP9DXtHlb98yCc0D
    /BNXWyYNC6LWfdyYnv69agXLigSReChhuqESylCKBJWP6j1Ulx2mYqGxQL5rS/TY
    n/jQzZork4Vmvmf4kuAGyvfy9ugIAi6eFqwEx4NAotz9Wxf2emNjijMsP+mI3N3R
    edXAHiCeZNwKgabEDk/Uw9izpRJl8qbgykB+toPvM7z9ZlaDsZPpJI6lkNLF2QQu
    VF0aBVUYsGX1BgP19cbrRmZ4KX1zNFo1JEkddzAjT5U3/dRpIHp5TOg/VYy/VR1A
    APCCHiBpb3VH33ByMMaTAEdey7KONho/lUHgKz31a7YVifT5BkiIlSpMHnMMMj4r
    -----END RSA PRIVATE KEY-----

    """

    static let rsaPKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDKWmwpzdgC9nX8
    zMyow1iYhcLpFZdjwZuuZRDew+srQp0n9sEiZsZuIVFxxarjDtNTF74NDfKpOHWq
    BqtSLzlkldYPKesXYtalt5VJ8CkI/MtgPR9vKRJ6lKlCVFjbz9Ux0CirD0w8qLwC
    QU2vGEj6eex33djsJYJssKwpZtj9ms2sqOvqA040zFUKLRFx0GC5CGxIXmJeONeJ
    z6w85/BW3Wp76W2MX7HrD1kM4eFPIBmE0sWDP5SI0XoU5bjtwk1kTstoWbRxM+Pi
    3OG2HCx9K2dgL2vb4XGgPXoM66TNX/8AGoYZjfP8KGolLeiO1QOsKTlEaNu+rqWr
    MAQMyJhHAgMBAAECggEATLib6f2xuO3ZLlA4CISIQsv0aotVKu1tKWIIU23U7EIF
    c/GKqJBvC7J2PrzDXfNxDEAkPq7bIm3VrvF4Y2CkUg69amJqUCOZXpuMbswvwsiW
    E5cZI/xelTtoMU3pou3Z11klEjZqoVUYc4JvAcQjZ1Ry47+pT1+pY6xYmhn0i7JJ
    RBQtONru0eDvVF8ytI34PVb01xhfqNRw1WXEGkYvVHMHLXtTQ25az9v/UEoJ20kJ
    +rV+KTwdKDiyg4s66WrpBlxjWLnDrfV5IxnRE/OK0YprJIc/fvR/ZzIBHqifxWtk
    7khxLVW6uzVqzWmQ70KeTX8uRFGM1tWVVWwwRZFfgQKBgQDpW2qqNrrCEaOdQe8N
    mzN0T7OLYs2gpgPMvFxnT0wMxz2p1kh+WfNtTJAqkUdgir18SVL4IEvXkKHEMklT
    Mm9TWck0J+A/EPOqNYUv+HLD4D9Z01DF8sx0HjKuhp66OVRdcBc7jRawk3xgRjZd
    plIWI+mpiT5/TsvlgQOW9XU+nQKBgQDd/N7MsWLX1TDyk4IFnOlHSbCsVQcLOg+G
    ANAkdC3XFpsEZFNJNrEwsQ3HVHCHTlQNx/ND69SEYkjSHKick4mDq9i8dBmOrp8Z
    8Gcle61gpe84FyXRh558UOeZE3hJN8iZOII5rN5fF7ui+vH0ey82jl+VoR9OAmfR
    XBrk6c/rMwKBgQC/+nE6L2RdnF1aVo/wRaqDGb7AATzh2TJvENeENnx+VruoKZ3i
    NOZLGR3Rp0ttZTaWNUyIzSkX4ujym9wvEeL8U3Vv7w5RVATiFr3HxUHFW4tCvtJI
    x4LkVKOlaSLUWa3KYRj76QqtoehE2/6F9Pq7NDhbPYmo+o5L9WOaob0fEQKBgQCL
    fgELI1R3R/IwHF0R5d34++dXAz8f4OYsUIp6vb6ob/4NLnXfhcymSjvcS8VCYQgU
    eNb2kVTDs3cLARM7AMLiyLOzCEmfDT/Q7u4B8cuq9dpypqkPF2eRus0ttbxaVgFp
    tsauM2Cw5Jr1+TbdaCLs515NCig/vuc5+eS0f/A1XQKBgA1p05eOClPtYTCefAU9
    7D1fAZod9a1kB2H35KXCiVhmEO2PzgVtBnbmmZvyXnLCm7xzFKVeNEI4F/zevgEY
    otYg1yOdm1iHJt0bmdgLqq/4SaDQPOFeFZZEhCfFPU3uvHeRKdskxS2rEUMb2yg9
    0UUj16eXHcspqrgMFYX2BLEW
    -----END PRIVATE KEY-----

    """

    static let rsaPKCS8Enc = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIIFNTBfBgkqhkiG9w0BBQ0wUjAxBgkqhkiG9w0BBQwwJAQQPyb5pqz0XP76Qxfu
    zA8s4wICCAAwDAYIKoZIhvcNAgkFADAdBglghkgBZQMEASoEEBqb7EoYr8jp35LY
    1AoLzvoEggTQnEzo08UrIHVBDA5lYoQHfkbhk+QrG0ls7HG0FKf7+MECrZ7urMEn
    gQbE1+7643EtcjRAzVJ4gc4UgJhuxxSrtHG4uj0fW+/uEW1eHr8Q1AtdJk80S+XS
    Bb/z5I/Yxe8nrEJyi9cpLi9TKSIIUYe+3CQ7bNqWN/G0IrxzjtoB3677Qgzc1bZB
    IY7cPPjrxW0btcsCEKtuUGZHDaplGAUh7zZ2OEnxjf/9hjFCo9lX8h10jZyeWSZ4
    FfGB2ziQDpi/qEF1BczjbI5mD06MKj1HJkEnwf7PfE05iJjXSj1u6U2cPc/icLwK
    KZjZxnfmPnArv6KLTTCI4COEqz66K2XcM2P8F5ogkcHo9RUCEb/7G0K8cY+teFKr
    2xIWdFExnpn5CReD6kAngBedk8tBsrI9X+AF/d1pH66cbxZuboqDgzQTd1lKb267
    WQ8m+AmMZ3QL37hM00Xg3rj5FfIbGCeceUokRm9kZ/3X5XoBaogmyCa24v4c6/G7
    eQpCTD8F6GW60Ky8Iq++kYFAYUciRFChD3lpKyvUzYiS1TiQqLF83+WHAHQpKI4s
    gRKYsJbo8BWXiKHn7WwqnQg7wDQsukrGixtjQLOR9lrz6n9pRvPsUtx+CpY6xPzp
    PM+NIE5iuZCZgQl3NzDi0j4uw4m5wnSzclRe40X+mqDgXt/cTz+BEbEQXiKtiH94
    LEWoCP2Iwctv9RehJVaNF/JNajsNHaiWnj+f3YF6+gYqhOA/hxZQUvP9O7TkssX8
    +JYtEUKzXzJ0fBbvHnaHuqkg8B2yIcyo4Hq7yrMsqCiNL0Zqy9yh9TpODO7L+eDq
    neZkYotEWaCEIspfpQRtYtWQ48Mv0xgo2oiZ53kH7o3f02/aIeJgQ5zEvStzduLc
    3oMYOZp+830eqb9gVhu8dzOj36n9hSvTk+EactDcXDlpzcK2pMsn8hp6bbH5joYN
    22Jgk5EJyYAL9wg11LI/8z4l+5miVPNeBwxIv8ZaPswmfQQc1icCTrSG2lgeBZR+
    7UogpdHW3ebxw5/YO3wLZwfpRVbhogaOihYJ72ALVHud4lkk7kgagJDMYq+5aiX5
    JG5q9Ke8PJR5oeLg8PKMw7CRV5bh0hMZzFSLhZbfSkV2n+WBuHFSSPp48ZOZG25A
    z447Rno0rrZ2fK9lXQl/qXm9uPXOklaR1lDfZNGu7F2ijqA5Ph3eByHA1BRK9jUf
    BKPwbCcn5ig8OB+RdOBQWWysQioQn8VKR4RO3QOE2vzPNshshIl68rFrM10e6PpG
    D2Yoml3247B9f1EB58TB8tp8yVD0lSDFzXaA3g4KxWfaV7Cqn0h73XSGvCxPK8ZZ
    p0s4MJSvZHPwF8Gz30t24N2X6KerWyX/1v3hlNufzv7nsnSEAtXJ6w3RfQoylMlr
    vYp1UepdtgDY6w2qBwcFjXIQjX5iURDneaqEtABnDXSPFb1oFgCEWNdXSAVuVozB
    560HWS9FmvNcBJuSHbHmOGvZR3Qxx4SKpU4/DpXaRLupMzQ2HVeAjAPWrh4uPvmT
    ffAhH+xS+0H4CbRAiPyvnku6HeO6z+1hUwHil6TherRhuOB6AIa7a58lh20zed9R
    B+6ztkatYsgXiffURP2fGHBsivh5gKmVGkg7rGeVKP/0xdNgBL0mEpg=
    -----END ENCRYPTED PRIVATE KEY-----

    """

    static let ed25519PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEIJnnDJ8MI9FIq+vDlys+0VUL8b/oJV1nrk66gYlt6D8w
    -----END PRIVATE KEY-----

    """

    static let ed25519PKCS8Enc = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIGjMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBCeaNGzElzMNuU/VJMg
    p9iRAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQXd0+JrPIMB0wxDPa
    NHWnKwRAzrYYmJlMYikRFM9uMEEqVuY4ryDCMNM+beTwmI6Oxvma3hLvQ/ed65+L
    /hOOHHl1krXaur3q9DBOPgANdr6AFg==
    -----END ENCRYPTED PRIVATE KEY-----

    """

    static let ecP384OpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
    1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQRMh9LU9TjYarEDHemesLgYKDb9ZknF
    JBG3BeCF1FfNMnKymCpDX0sdhwHIRn968RK5uwvIuJAqex1SVJWhT7Wwg3WnWyHCbSUSq1
    HN7YnO1a8Xr7WIX9n3UFSupVjQo0MAAADYXPg9lVz4PZUAAAATZWNkc2Etc2hhMi1uaXN0
    cDM4NAAAAAhuaXN0cDM4NAAAAGEETIfS1PU42GqxAx3pnrC4GCg2/WZJxSQRtwXghdRXzT
    JyspgqQ19LHYcByEZ/evESubsLyLiQKnsdUlSVoU+1sIN1p1shwm0lEqtRze2JztWvF6+1
    iF/Z91BUrqVY0KNDAAAAMEnwrjTVK3NrWYLoiqApzQzrUqtV3HByneRHrPAjWjGia1jW6p
    DIF3yAMn+SBtbR/QAAAAp1dGVybS10ZXN0AQIDBAUG
    -----END OPENSSH PRIVATE KEY-----

    """

    static let ecP521OpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
    1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQBPwhlzAbrUkPgGC+VGkEazrhsFAnN
    UQZyncM/BGa7+aWP49kdlAn4o7mVtU8FoWHA3h2udC6LxTTjEqQWWDKwmTwATiOyxpPxIs
    BZ53INBPGbBwTv6x5+GVl9ppGo/vCwTaotHTIz6pgPA0L2sKS9Qbmu+wNgrL6ZkJ5EHiXw
    dg4FLToAAAEI37TySt+08koAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
    AAAIUEAT8IZcwG61JD4BgvlRpBGs64bBQJzVEGcp3DPwRmu/mlj+PZHZQJ+KO5lbVPBaFh
    wN4drnQui8U04xKkFlgysJk8AE4jssaT8SLAWedyDQTxmwcE7+sefhlZfaaRqP7wsE2qLR
    0yM+qYDwNC9rCkvUG5rvsDYKy+mZCeRB4l8HYOBS06AAAAQgCqtvFA+qXE6zRMIHSsClRy
    vEdUrYWZXni+L5RYAsVJW1Tp0W8jtQ44ip3+LzYqWbqybrcQEmiVgwxlAaY7JKeSiQAAAA
    p1dGVybS10ZXN0
    -----END OPENSSH PRIVATE KEY-----

    """

    static let ecP256SEC1 = """
    -----BEGIN EC PRIVATE KEY-----
    MIIBaAIBAQQgP2S/SdphrVls7OV8UhmptnIsL7tCM6DFMdCy6owc6ISggfowgfcC
    AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
    MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
    vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
    axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
    K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
    YyVRAgEBoUQDQgAEXRMZ+4O39C6BzOPMDh9vLVYxyE86Ebdfql1eTYyZTqf3TVf6
    sKWv730FExKc1iLmNwPulEF5l+PoKyYFkoUhzg==
    -----END EC PRIVATE KEY-----

    """

    static let ecP384SEC1 = """
    -----BEGIN EC PRIVATE KEY-----
    MIIB+gIBAQQwxFvnry3gO9/XPH+O6nNekzGNGQ/ZscnjqR30+HMJO/sbXDMTVECo
    fYd0tLVb9O47oIIBWzCCAVcCAQEwPAYHKoZIzj0BAQIxAP//////////////////
    ///////////////////////+/////wAAAAAAAAAA/////zB7BDD/////////////
    /////////////////////////////v////8AAAAAAAAAAP////wEMLMxL6fiPufk
    mI4Fa+P4LRkYHZxu/oFBEgMUCI9QE4daxlY5jYou0Z0qhcjt0+wq7wMVAKM1kmqj
    GaJ6HQCJamdzpIJ6zaxzBGEEqofKIr6LBTeOscce8yCtdG4dO2KLp5uYWfdB4IJU
    KjhVAvJdv1UpbDpUXjhydgq3NhfeSpYmLG9dnpi/kpLcKfj0Hb0omhR86doxE7Xw
    uMAKYLHOHX6BnXpDHXyQ6g5fAjEA////////////////////////////////x2NN
    gfQ3Ld9YGg2ySLCneuzsGWrMxSlzAgEBoWQDYgAETq47BSduP22gl965+7tO/LUw
    FsB6/2+crSy6LmhFAcBA+2GWyFzOuBJyN558PK50sXQYjdUVZB9kYaCcGRydaUWx
    IbEtCmCJxPyVN/LRuqSOeRg2KaxQIjep2+NrmDCi
    -----END EC PRIVATE KEY-----

    """

    static let ecP521SEC1 = """
    -----BEGIN EC PRIVATE KEY-----
    MIICnQIBAQRCAVf/6/kCdKF2RY8Gky/ldx6Dm8P7a4KBhM0y2I2G0nL6OZ1RhjMu
    ZXfHMA8eNY/Af1AoVDE5icybnGne/LI8Jf1hoIIBxjCCAcICAQEwTQYHKoZIzj0B
    AQJCAf//////////////////////////////////////////////////////////
    ////////////////////////////MIGeBEIB////////////////////////////
    //////////////////////////////////////////////////////////wEQVGV
    PrlhjhyaH5KaIaC2hUDuotpyW5mzFfO4tImRjvEJ4VYZOVHsfpN7FlLAvTuxvwc1
    c9+IPSw08e9FH9RrUD8AAxUA0J6IACkcuFOWzGcXOTKEqqDaZLoEgYUEAMaFjga3
    BATpzZ4+y2YjlbRCnGSBOQU/tSH4KK9ga009uqFLXnfv51ko/h3BJ6L/qN4zSLPB
    hWpCm/l+fjHC5b1mARg5KWp4mjvABFyKX7QsfRvZmPVESVebRGgXr70XJz5mLJfu
    cple9CZAxVC5AT+tB2E1PHCGonLCQIi+lHaf0WZQAkIB////////////////////
    ///////////////////////6UYaHg78vlmt/zAFI9wml0Du1ybiJnEeuu2+3HpE4
    ZAkCAQGhgYkDgYYABAEtKfn1f6nj7ZCWOm9q/5aFHZnenIyEbcI6uJP5XOB2OXKk
    3qck9xtmir0UcDcqEW0DuYlfcuHzrnynYg/ilh0Z3QE0atUHvTXQJyqBXL6mxd3j
    pqkLfnnItR1XhgjKVQUthjDr5EOR5/K4MWQ9xHLwzLIzAiF2wDxOSZnmwyIl9eXr
    OA==
    -----END EC PRIVATE KEY-----

    """

    static let ecP256SEC1Enc = """
    -----BEGIN EC PRIVATE KEY-----
    Proc-Type: 4,ENCRYPTED
    DEK-Info: AES-256-CBC,40E1FD40CC57106D51FA2879B0F1F13E
    
    GRgEzUtY31uLMbMlFNaC6o9kvGY8ccm02jg9NKdASKyK4KlXtLFWbBkBiZU7i2uZ
    jPd5vB47pPINMwzxE1aVSZL9ACT2xtOZig0cimMcJPQgzwAG8eWSqFdoV5uB1CDI
    iH1VfJciwiGMREuO2Rup2Imdgb8/Oxd9uBvTMTi1JHt0cXPm8BgthJi0bdaheHgD
    /LfG+TBtc8CQstbJW3NFRN3dVu3wUDzin3C0KbCF9jAbdyHL/hgHMG5JC5T0j4YJ
    BuiXDIKdaKK3NAXet2WASzr/6yE8t3W/bulm9VAPsnv2cfITstT0yCHMOJ5roGJS
    D0KOZbIE06FLoV/ARPzNcLbUdZc+wP4/HcOmHr1vJ5qA2wZb0s3sovLUHI3EA6kO
    tu8bhHK7rx87+y9wgyHA7qF3VwZyyh2CseVBLCFJ4R7mtd0waC2zDAXJLRDDtzYa
    tOAR2/fGuLUoVwbs/B2qzij35PFEgUOXd8kYkYd8wEc=
    -----END EC PRIVATE KEY-----

    """

    static let ecP256SEC1Named = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIBYqpoo9bswyE04AW8sMgZQljY9w2vy6VZuAX0qPCNVioAoGCCqGSM49
    AwEHoUQDQgAEwWPl4ip3KtWhEcMCdfXb+D2P6vx3Uh6usj9R19mmBTjqg34g6g82
    AvECCW++ISd/XCgitnFnefVNU/XayTY5iQ==
    -----END EC PRIVATE KEY-----

    """

    static let ecP256PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MIIBeQIBADCCAQMGByqGSM49AgEwgfcCAQEwLAYHKoZIzj0BAQIhAP////8AAAAB
    AAAAAAAAAAAAAAAA////////////////MFsEIP////8AAAABAAAAAAAAAAAAAAAA
    ///////////////8BCBaxjXYqjqT57PrvVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMV
    AMSdNgiG5wSTamZ44ROdJreBn36QBEEEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg
    9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9QIhAP////8A
    AAAA//////////+85vqtpxeehPO5ysL8YyVRAgEBBG0wawIBAQQgP2S/SdphrVls
    7OV8UhmptnIsL7tCM6DFMdCy6owc6IShRANCAARdExn7g7f0LoHM48wOH28tVjHI
    TzoRt1+qXV5NjJlOp/dNV/qwpa/vfQUTEpzWIuY3A+6UQXmX4+grJgWShSHO
    -----END PRIVATE KEY-----

    """

    static let dsaPEM = """
    -----BEGIN DSA PRIVATE KEY-----
    MIIBzAIBAAKBgQDnsL4kQPdQhg36lHxRJ+wOsUpacIX4nB/l+qrLgjXhUu7W4Mxp
    r9p/60npzPlqzmPUt1PZe0YxDcaF3TBCwAEdFhbDRWkhm8Hi4r/rxbsRxxxZIO8O
    0hLa+Zqovk1J/jNOP1qKfDsFwth3hQ/McDacCHteLIPhEE79ZGp3JWE9sQIdAKux
    DCNfbL/evsAx1hodBVb2pPUtoLOI9feerk0CgYEA2EpPkQlc5xXh7Q7wZVMejgmN
    dMUoONHUCJbVrcXx1Zj3up6IhqA4O9B7doBdVa2Lx6gd81ZK1ril/P+/yms7a7BW
    qRCN9DmreFzr3vNvBwAwO9wMYWACd1emsqfD4XqoJWFbuiZQrtTYRLmZm8KNOmgI
    Hn63Rgw7raQ4kjfvD8UCgYEAjU5ZnyeyxjPeekwjO5WR7xGhv8gBHbURlFGahTGj
    +0CT9twJGnVrHJuOfD4x4cVBTF6Tp/47jyaAxzOtol78B2DkYT3TiixFpFh+tafb
    APt9d0E8wpaoz091gaMj/1WUStCriJ0TFdSrsN3m6AJcQBoOJdv2oNnsDgz1eAWQ
    jMUCHGSdDtjwTgcqWfU/Sp9R7aHyVhfkQ5/3yv5+yKw=
    -----END DSA PRIVATE KEY-----

    """

    static let ed25519OpenSSHEnc = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABDyyQ80tq
    Rlq1u/PNYm+ygtAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIEyuc/vRt3gJZB3E
    abJ7vdFyBht1dN5U9Wl/T4fFY5eYAAAAkKCiY8ogP30eBSwqkvs8YBQDrnW4Rm9MmxKgPK
    p+c2/8sFJYHuWdL6zpbmwJfrEZa/BI5l5jDu1CHnQkryafvxNCz/WKgVgFzqmtpy0l3H3d
    y550TL6/xglyC4iNsz7TZunkBGvjy1CaLLmfuLwCTff0ykbAilaXFSLV1ALUYV08fEzbmZ
    1dZeRPZNHeKMvSdw==
    -----END OPENSSH PRIVATE KEY-----
    """
}
