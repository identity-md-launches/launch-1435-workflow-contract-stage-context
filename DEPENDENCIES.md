# Vendored dependencies

All dependency files are ordinary source files inside this repository. There are no submodules or package-install steps in the build.

| Dependency | Pinned version | Vendored content | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.5.0 | Transitive Solidity source closure required by contracts/tests (28 files) | MIT, `lib/openzeppelin-contracts/LICENSE` |
| forge-std | v1.9.7 | `src/` | MIT / Apache-2.0, licenses in `lib/forge-std/` |

Archive provenance:

- OpenZeppelin: `https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.5.0`; SHA-256 `95a4e1ff7a01da7d875e7872b6160337561efd7fb0a8751de76e837a10d90cbf`.
- forge-std: `https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7`; SHA-256 `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94`.

`src/OracleAttestation.sol` and the conformance vector/constants were copied from the supplied pinned IdentityMD oracle-consumer reference. The library and base consumer are unchanged. v5.5.0 provides the canonical reference's `SignatureChecker.isValidSignatureNowCalldata` API; v5.4.0 does not. All production library calls are internal and leave no bytecode linking placeholders.
