extension UpdateSignature {
    /// The PKCS#1 `RSA PUBLIC KEY` that every update must verify against, made by `scripts/update-feed.sh genkey` for LoftLine
    /// releases. It is also committed as `packaging/updater/update-public-key.pub`, which `scripts/verify-feed.sh` reads; a test
    /// keeps the two equal. Its private half lives only in `~/.config/loftline/update_sign.key` and in the Actions secret
    /// `UPDATE_SIGN_KEY`. Every shipped app pins this key, so changing it needs a release signed with the old key that carries
    /// the new one (docs/DECISIONS.md `feed-signature`).
    public static let publicKeyPEM = """
        -----BEGIN RSA PUBLIC KEY-----
        MIICCgKCAgEAtbudglEuZrLLqUjd8ZzTwaIbOWgE4FRkswjNAvUsEAS9ZDQCnTmO
        pFWkv9t3jvdaYEWeYDUiewTZLQyNeS8OROOcNPv5DFziFzxzcEEwir2zQq35rGrj
        KCAc6UmRq/VO1KXu4H7TxGlsXK6Fr9dRIxg6KetEubiZGZ2hZcSBU+mMVAy1cnjm
        CT6PRRv792PdN2Qj6ksZeuHCu8FrJlSK83KzbjZWlVd9NC6HKKCWa2glY5AKiHLt
        jK5jtzHiZm7IuyAF4BDBAnhrI44xWVrnWiq2rWVyBiV/25c96+C45r2Etgcy29t7
        Bs46LgWa+p5xyL2rd0uCjWR0uxLUmMEmBGbxr9p3UDlcrutU4zoe+Bq3qgWkV9uI
        /BNqjopal9AVkaKrQcEEYg5uK2nW+MTInhW38AQ546vJvPluYF/dRWxNL3P2axA/
        6WTzTLQXqfNTOTnRZTWI+RiX7VqySy2+X+GL2lnr3Ob0WpupvWeR8YhHTBLOK3LB
        zrPh3OmLPz+IYLLqB+YkuwUW0B6onL5a09r9yV2hUsW8f5FLYHpPSE0Gcz0NFcMv
        eYavlgrlMMIMFxx5k/E7SrLmSklXkKk8jrd4kGTosBSKTkRhy/UUj/L4ZGLn2Wy3
        W3xNO9d567LM8uU+/9eeduI3B6M38vUiOiyMLKLK4TRVxUWJChkLJLkCAwEAAQ==
        -----END RSA PUBLIC KEY-----
        """
}
