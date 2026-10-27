# Repository instructions

## Bilingual documentation

The project documentation is maintained in two languages:

- `README.md` (symlink to `README.oracle_fdw`) — English, the source of truth
- `README.ru.md` — Russian translation

**Rule:** every documentation change must be applied to both files in the
same commit. When you add, change or remove a section, option, example,
note or link in one language, make the matching change in the other.
Do not merge or commit documentation changes that leave the two versions
out of sync; if you find them out of sync, restore parity first.

Note: `README.md` is a symlink; edit the real file `README.oracle_fdw`
(or edit through the symlink). `README.ru.md` is a regular file.
