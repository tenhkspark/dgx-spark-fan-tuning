# Publishing checklist

The repository is in a push-ready state. Creating the remote is a separate, explicit step.

## Before the first push

1. `gh auth status` — the account needs `repo` scope.
2. Personal-information scan over the whole worktree:

   ```sh
   grep -rInE '(192\.168\.|10\.[0-9]+\.[0-9]+\.|100\.[0-9]+\.[0-9]+\.[0-9]+|\.ts\.net|/Users/[a-z]+/|/home/[a-z]+/|gho_|github_pat_|sk-[A-Za-z0-9]|AKIA|xox[abp]-|BEGIN [A-Z ]*PRIVATE KEY)' .
   ```

   Host names in `scripts/` must stay placeholders (`node1 node2`, `<host>`).
3. `git log --format='%an <%ae>%n%b'` — author is the noreply identity, no `Co-Authored-By`,
   no session URLs, no tool signatures.
4. `git remote -v` empty.
5. Confirm the patch still applies cleanly to the current upstream checkout:

   ```sh
   tmp=$(mktemp -d); git clone -q --depth 1 https://github.com/christopherowen/dgx-spark-fan-control "$tmp"
   ( cd "$tmp" && patch -p1 --dry-run < /path/to/patch/0001-performance-curve.patch )
   rm -rf "$tmp"
   ```

## Create the remote (only when asked to publish)

```sh
gh repo create <owner>/dgx-spark-fan-tuning --public --source=. --push \
  --description "Fan curve notes and a one-patch tuning for 4-node DGX Spark clusters: the 0-RPM trap, measured idle/load RPM, and the October firmware that breaks fan control. (EN/KO/ZH/JA)"
```

Verify by reading a file back over HTTPS, e.g.
`curl -s https://raw.githubusercontent.com/<owner>/dgx-spark-fan-tuning/main/README.md | head -3`.

## License note

The patch modifies a GPL-2.0 project, so this repository is GPL-2.0 as well
(`LICENSE` is the upstream text). Keep the upstream credit in `README.md` and in the
patch header when you edit either.
