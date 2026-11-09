# subenum

Passive + active subdomain enumeration wrapper for common Go/Python recon tools.

## Install / requirements

- bash (Linux)
- Used if installed: `subfinder`, `amass`, `assetfinder`, `findomain`, `puredns`, `curl`
- Missing tools are reported and skipped; a warning lists what would improve coverage.

## Install on a new machine

```bash
git clone https://github.com/<YOUR-USERNAME>/subenum.git
cd subenum
chmod +x subenum.sh
mkdir -p ~/.local/bin
ln -sf "$(pwd)/subenum.sh" ~/.local/bin/subenum
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
exec bash   # reload shell
```

Optional but recommended:

- puredns resolvers file at `~/.config/puredns/resolvers.txt`
  (one resolver per line, e.g. public resolvers; a custom path is asked at
  runtime if the file is missing)
- API keys configured for the passive tools (subfinder/amass `provider-config`)
  to maximize each source's coverage

After this, run it from any directory as `subenum ...`. Results go to the
directory the script lives in (`recon/` inside the cloned repo), because the
script resolves its own symlink.

## Install (callable from anywhere)

```bash
# one-time setup (run it from anywhere; uses your home path):
ln -sf "$HOME/Tools/asm/subenum.sh" ~/.local/bin/subenum
echo 'alias subenum="$HOME/Tools/asm/subenum.sh"' >> ~/.bashrc
exec bash   # reload shell aliases
```

After this, run it from any directory as `subenum ...`. Results still go to
`~/Tools/asm/recon/` (the script follows its own symlink).

## Usage

```bash
chmod +x subenum.sh
./subenum.sh target.com
./subenum.sh target1.com target2.com target3.com
./subenum.sh --list targets.txt
./subenum.sh -l targets.txt extra.com      # list file + extra targets combined
./subenum.sh -o /path/to/results target.com   # custom results folder
./subenum.sh --help
```

### Custom output folder

By default results go to `~/Tools/asm/recon/`. To use your own
dedicated folder instead:

```bash
subenum -o /path/to/my-results target.com        # one run
subenum -o ~/subdomain-enum-results -l targets.txt
```

- The folder is created if it does not exist (parents included).
- The same structure is built inside it: `<folder>/<target>/{passive,active,final}/`.
- Existing files in that folder — including older `final/` files - are untouched;
  each new run only ADDS new timestamped files.

### Target list file

- One domain per line, e.g.
  ```
  # my targets
  target.com
  target2.com   # comments allowed
  ```
- Blank lines, whitespace, and `#` comments are ignored.
- Entries that are not valid domains are reported and skipped.
- Missing/empty list file: the script stops with a clear error.
- One `--list` file per run, but you can mix it with extra domains given
  directly on the command line.

## Flow

1. **Passive** for every target, one tool after another:
   - `subfinder -d <t> -all`
   - `amass enum -d <t>` then, after it completes, `amass subs -names -d <t>`
   - `assetfinder --subs-only <t>`
   - `findomain -t <t>`
   - crt.sh certificate transparency via `curl`
   - hackertarget hostsearch via `curl`
2. Merge + dedupe per target into `final/`.
3. **Pause:** the script asks `Go for ACTIVE enumeration? [yes/no]`.
4. **Active** (only if you say yes, needs `puredns` + a wordlist):
   - `puredns bruteforce <wordlist> <target> --rate-limit 50 -t 20 --rate-limit-trusted 50`
   - bruteforce only, no resolve step (subdomain-enum scope; live-check
     hosts with httpx etc. separately)
   - rate limited to avoid bans
5. Final report: per-tool counts and merged totals.

## Output structure (one folder per target)

Results are ALWAYS saved under the script's own directory
(`~/Tools/asm/recon/...`) no matter which directory you run the
tool from.

```
recon/<target>/
├── passive/
│   ├── subfinder.txt
│   ├── amass_enum.txt
│   ├── amass_subs.txt
│   ├── assetfinder.txt
│   ├── findomain.txt
│   ├── crtsh.txt
│   └── hackertarget.txt
├── active/
│   ├── puredns.txt
└── final/
    └── <target>_subdomains_<YYYYmmdd_HHMMSS>.txt
```

- Files are named after the tool that produced them.
- Every `final/` file has a timestamp: old results are NEVER deleted or overwritten.
- `*.` wildcard prefixes are stripped before results are saved and merged.

## Network loss handling

Removed (per request): the script no longer pauses or monitors connectivity -
tools run in sequence and the script proceeds without interruption.

## puredns resolvers

puredns needs a resolvers list. The script:

1. Checks the puredns default `~/.config/puredns/resolvers.txt`.
2. If that file exists and is non-empty, nothing extra is passed to puredns.
3. If it is missing/empty, the script asks for a custom resolvers file path
   and passes it automatically as `--resolvers <file>` to `puredns bruteforce`.

Your machine already has `~/.config/puredns/resolvers.txt`, so in practice you
will not be prompted.

## Optional per-tool timeout

Some tools hang for long periods on slow upstream sources (e.g. subfinder's
`-all` mode). To enforce a per-tool wall-clock limit:

```bash
TOOL_TIMEOUT=150 ./subenum.sh target.com   # seconds; applies to each tool
```

- Default: 0 / disabled - tools run exactly as specified, no change.
- Requires the `timeout` binary (present in normal Linux installs).
- A killed tool is reported as failed and the run continues with the next tool.

## Delay between tools (API-rate protection)

Many subdomain sources fetch data with YOUR API keys (subfinder providers,
crt.sh, resolvers used by puredns, etc.). To spread the requests out:

```bash
TOOL_DELAY=10 ./subenum.sh target.com       # sleep 10s before EVERY tool call
TOOL_DELAY=5 ./subenum.sh -l targets.txt    # also delays between targets
```

- Applied before each passive tool AND before the active (puredns) run.
- Default: 0 / disabled - tools run back-to-back as before.
- The wait is logged: `waiting 10s before crt.sh (TOOL_DELAY ...)`.

## Per-query delay (`-q/--query-delay`), NOT set by default

Slows requests to protect API keys configured inside tool config files.
This maps the delay onto each tool's NATIVE rate option:

| tool       | option used            | notes                                      |
|------------|------------------------|--------------------------------------------|
| subfinder  | `-rl 1`                | ≤1 HTTP request/second (integer granularity) |
| findomain  | `--rate-limit <delay>` | exact: seconds between queries              |
| puredns    | `--rate-limit <1/delay>` | queries/second; capped at 1              |
| amass      | NONE (v4 has no rate flag) | only `TOOL_DELAY` spacing applies       |
| crt.sh / hackertarget | (one request each) | covered by the wait before the tool   |

```bash
subenum -q 5 target.com           # 5 seconds between queries where supported
subenum -q 0.5 target.com         # half second => 2 req/s
```

Defaults: everything off. No delay, no timeout, normal verbosity.

## Tool output modes (default: see everything)

DEFAULT: every tool runs with its own natural output visible - amass's
enumeration progress bar (`0 / 101 [----] 0.00% ? p/s`, printed on stderr),
subfinder's source status lines, findomain's messages.

amass reprints its bar on EVERY poll (flooding the terminal). The script
THROTTLES it: one single in-place updating line, redrawn every
`AMASS_BAR_INTERVAL` seconds (default 30). Real diagnostics (API errors,
warnings) still print immediately.

```bash
subenum -s target.com     # quiet run: tools silenced (-silent/-q), no banner,
                          # no headers/summaries, tool stderr dropped
subenum -v target.com     # natural output PLUS each tool's verbose flag
                          # (subfinder -v, findomain -v; amass unsilenced anyway)
```

- Found subdomains are collected identically in every mode.
- The amass progress bar lives on stderr, so it can never pollute the results
  .txt files.
- `-v`/`-s` change only what you SEE, never what is collected.

## Making it faster: `-p/--parallel`

By default passive tools run one after another (so `TOOL_DELAY` and API
protection behave predictably). If API consumption is not a concern:

```bash
subenum -p target.com                 # all passive sources simultaneously
subenum -p -l targets.txt             # same for list runs
subenum -p -v target.com              # but -v output interleaves
```

- One wall-clock pass instead of 6 sequential tool runs - typically
  several minutes faster per target when subfinder/amass hang on slow sources.
- TOOLS still write their own separate files; merging is unchanged.
- In this mode `TOOL_DELAY` cannot be honored between tools (sources query at
  the same time) - it still applies between targets.
- Combine freely: `TOOL_DELAY=60 TOOL_TIMEOUT=150 ./subenum.sh target.com`

## Notes

- Target list file: one domain per line; `#` comments and blank lines ignored.
- Active enumeration needs the `puredns` binary; you get the wordlist prompt
  only if you choose to go active.
- Aliases/similar targets: each target gets its own `recon/<target>/` folder, so
  files never collide across targets.
