# openclaw-signup

An [OpenClaw](https://docs.openclaw.ai) skill that signs you up for events. Send your
agent an event link - Luma, Eventbrite, a Google Form, a hackathon portal, a waitlist -
and it opens the page in the OpenClaw browser, fills the form with your details and
submits it.

When it hits something only you can do (a captcha, an email code, a payment, a question
your profile doesn't answer), it stops and sends you the link, everything it filled in,
and what's left. It also queues the event for `/signup`, a Claude Code skill that opens
it in your own Chrome, fills it in again and leaves only the human part to you. Nothing
here guesses facts about you or pays for anything.

Works with any working OpenClaw on macOS or Linux.

## How it works

```
you: https://lu.ma/some-event
          |
          v
 agent reads AGENTS.md  ->  "event link? use the event-signup skill"
          |
          v
 event-signup skill: open page in the OpenClaw browser, fill from your profile, submit
          |
          +-- success  ->  "Registered: <event>, <date>, <confirmed / waitlist / pending>"
          |
          +-- blocked  ->  "Couldn't finish: <event> / <link> / Blocked by: <captcha...>
                |           Filled in so far: ... / Left for you: ...
                |           Queued for /signup: <id>"
                v
       queue (a folder, or a private git repo if OpenClaw runs on a server)
                |
                v
 you, in Claude Code: /signup  ->  opens each queued event in your Chrome, fills it in,
                                   stops before submit; you do the captcha and submit
```

Your details live in `profile.md`, which never leaves your machine: `install.sh` copies
it into the skill file at install time, so the agent needs the browser tool but no file
access.

## Setup

You need a working OpenClaw (gateway running, an agent you can chat with), Chrome,
Chromium, Brave or Edge on the machine OpenClaw runs on, and `python3` for the queue.
`/signup` (step 6) also needs Claude Code on the computer you sit at.

### 1. Get the repo

```sh
git clone <this repo's URL> openclaw-signup
cd openclaw-signup
```

### 2. Write your profile

```sh
cp profile.example.md profile.md
```

Open `profile.md`, replace every example value with your own, and delete the
`<!-- TEMPLATE ... -->` line at the top. The agent uses only what's in this file, so:

- Put in everything you'd normally type into event forms (name, email, company, links).
- Use the email your Luma account uses, so tickets land in your account.
- Write the "What are you building?" answer exactly as you want it pasted, on one line.
- Leave out anything you don't want on forms. A missing field gets handed back to you,
  not invented.

`profile.md` is in `.gitignore` - it is never committed.

### 3. Give your agent the browser

The common `coding` tool profile does not include the browser. Check:

```sh
openclaw config get tools.profile
openclaw config get tools.alsoAllow
```

If the profile is `coding` (or another restricted one) and `alsoAllow` doesn't list
`browser`, add it. **`config set` replaces the whole list**, so include anything that was
already there:

```sh
openclaw config set tools.alsoAllow '["browser"]'          # plus your existing entries
openclaw gateway restart
openclaw browser doctor                                      # should report ready
```

### 4. Install

```sh
./install.sh
```

This builds the skill from your profile, installs it for all your agents as
`event-signup`, checks that OpenClaw shows it to the model, and adds a short routing
block to your default agent's `AGENTS.md` (see [Routing](#routing)).

Options: `--agent <id>` installs for one agent only, `--no-routing` leaves `AGENTS.md`
alone, `--render-only` just builds `build/event-signup/SKILL.md` so you can read it.

### 5. Log the browser in to Luma (once)

Luma lets a signed-in browser register in one click. Signed out, it emails a code the
agent can't read, so those events come back to you. The OpenClaw browser has its own
profile, separate from your normal Chrome, so it needs its own login. Log in by hand -
never give the agent your password.

**On a Mac or a Linux desktop:**

```sh
openclaw browser start
openclaw browser open https://lu.ma/signin
```

An orange-tinted Chrome window opens. Sign in there. The login is kept for next time.
Do the same for any other site where you want one-click registration.

**On a Linux server:** see [Running on a Linux server](#running-on-a-linux-server).

### 6. Set up `/signup`

`/signup` finishes the events the agent got stuck on. It runs in Claude Code and opens
each queued event in your own Chrome, where you are signed in. It fills in everything
the agent knew and stops before submitting, so you only solve the captcha (or fill the
missing field) and click submit.

On the computer you sit at, you need [Claude Code](https://claude.com/claude-code) with
the [Claude in Chrome](https://claude.ai/chrome) extension, and `python3`.

**If OpenClaw runs on this same computer:**

```sh
./install-claude-code.sh
```

Both sides use the folder `~/.openclaw-signup` as the queue. Nothing else to set up.

**If OpenClaw runs on another machine (a server),** the queue travels through a private
git repo:

1. Create a private repo that already has a first commit:
   `gh repo create signup-queue --private --add-readme`
2. On the server, as the user that runs OpenClaw, clone it with push access (an SSH
   deploy key with write access works well), and point the skill at it:

   ```sh
   git clone git@github.com:<you>/signup-queue.git ~/signup-queue
   ./install.sh --queue-dir ~/signup-queue
   ```

3. On your computer:

   ```sh
   git clone git@github.com:<you>/signup-queue.git ~/signup-queue
   ./install-claude-code.sh --queue-dir ~/signup-queue
   ```

The queue holds the values the agent filled in from your profile, so keep that repo
private.

**Using it:** when the agent writes `Queued for /signup: <id>`, start Claude Code with
Chrome connected (`claude --chrome`, or `/chrome` in a running session) and type
`/signup`. It works through every queued event, one tab each.

If you already have a `/signup` command or skill, the installer leaves it alone and
stops. Install under another name with `./install-claude-code.sh --name <name>`.

### 7. Try it

In your chat with the agent, send `/new` (so it starts a session with the new skill),
then send an event link on its own.

## Updating

- **Changed your profile?** Run `./install.sh` again.
- **New version of this repo?** `git pull`, then `./install.sh` and
  `./install-claude-code.sh` (with the same options as the first time).

All of these are safe to repeat: the skills are replaced and the routing block is
updated in place.

## The queue

Blocked events go into `signups.jsonl` in the queue folder. Each line is one event,
"queued" or "closed", and lines are only ever added, never changed. That is what lets
the server and your computer both write to the queue between syncs: git's union merge
keeps both sides' new lines, so a sync never conflicts.

`/signup` closes an event once it has filled the form in and handed the tab to you. If
you don't finish one, send the link to your agent again and it goes back in the queue.

To see what's waiting: `bash ~/.claude/skills/signup/signupq list`.

## Routing

Some model runtimes (for example Claude through the `claude-cli` runtime) see OpenClaw
skills by name only, without their description. Then a bare link never triggers the
skill and the agent just asks "want me to register you?". So `install.sh` adds this to
your agent's `AGENTS.md`, which OpenClaw loads on every turn:

```markdown
<!-- event-signup:start - added by openclaw-signup/install.sh; ... -->
## Event signups

When the user sends an event, registration, waitlist or RSVP link - even a bare
link with no other text - sign them up with the `event-signup` skill: read
`<path to SKILL.md>` and follow it. ...
<!-- event-signup:end -->
```

Everything else in `AGENTS.md` is left as it was. To remove it, delete the block.

## Running on a Linux server

Without a screen, OpenClaw starts Chrome headless. Many signup pages (Luma among them)
run bot checks that headless Chrome fails, so give it a virtual screen with Xvfb.
These steps assume the gateway runs as the user service that `openclaw gateway install`
creates (`openclaw-gateway.service`); run them as the user that runs OpenClaw.

1. Install Google Chrome from Google's `.deb` (Ubuntu's `chromium` is a snap and
   OpenClaw can't drive it), plus Xvfb:

   ```sh
   wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
   sudo apt install -y ./google-chrome-stable_current_amd64.deb xvfb
   openclaw config set browser.executablePath /usr/bin/google-chrome-stable
   openclaw config set browser.noSandbox true
   openclaw config set browser.headless false
   ```

2. Run a virtual screen `:99` as a service. Create
   `~/.config/systemd/user/xvfb.service`:

   ```ini
   [Unit]
   Description=Virtual screen for the OpenClaw browser

   [Service]
   ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x900x24
   Restart=always

   [Install]
   WantedBy=default.target
   ```

3. Point the gateway at it: `systemctl --user edit openclaw-gateway.service`, add

   ```ini
   [Unit]
   Requires=xvfb.service
   After=xvfb.service

   [Service]
   Environment=DISPLAY=:99
   ```

   then:

   ```sh
   systemctl --user daemon-reload
   systemctl --user enable --now xvfb.service
   systemctl --user restart openclaw-gateway.service
   loginctl enable-linger "$USER"     # keep both running after you log out
   openclaw browser status --json     # headlessSource must not be "linux-display-fallback"
   ```

4. **Log in to Luma through VNC** (once). You need to see the virtual screen:

   ```sh
   # on the server
   sudo apt install -y x11vnc
   x11vnc -display :99 -localhost -rfbport 5900 -nopw -forever
   ```

   ```sh
   # on your own computer, in a second terminal
   ssh -N -L 5900:localhost:5900 you@your-server
   ```

   Open `vnc://localhost:5900` (macOS: Finder > Go > Connect to Server; elsewhere any
   VNC viewer). On the server, run `openclaw browser open https://lu.ma/signin`, sign in
   by hand in the VNC window, then stop `x11vnc` with Ctrl-C. (`-localhost` means VNC is
   only reachable through your SSH tunnel.)

## Troubleshooting

| What you see | What to do |
|---|---|
| The agent asks "want me to register you?" or asks for details that are in your profile | It didn't load the skill. Send `/new`. Check the routing block is in the right agent's `AGENTS.md` (`openclaw agents list` shows each agent's workspace). As a one-off, say "sign me up with the event-signup skill: <link>". |
| "Browser disabled" or the agent has no browser tool | Step 3. If you use a `plugins.allow` list, it must include `browser`. Restart the gateway after config changes. |
| `Failed to start Chrome CDP` on Linux | Snap Chromium. Install Google Chrome from the `.deb` (server step 1). |
| Every event comes back "blocked by captcha" | On a server: headless Chrome is being caught - set up Xvfb. On a desktop: the site wants a human; finish it from the message. |
| Luma events come back "signed out" or "email code" | Log the OpenClaw browser in again (step 5). |
| Sending several links at once goes wrong | There is one shared browser. The skill does them one by one, but sending one link per message is the safest. |
| The agent writes `Not queued: ...` | It could not run the handoff script. Usually OpenClaw's exec policy (`openclaw approvals get`) or no `python3` on the OpenClaw machine. The chat message still has everything you need. |
| `/signup` says "No pending signups" but the agent queued one | Server setup: on the server run `git -C ~/signup-queue push` and read the error. Most often the server's clone has no push access. |
| `/signup` says Chrome isn't connected | Start Claude Code with `claude --chrome`. The extension must be signed in to the same Claude account as Claude Code. |

The installers refuse to run with an unedited profile template, a profile without a
name or email, when OpenClaw doesn't show the skill as visible to the model, or when
they would overwrite a `/signup` they didn't create, and they say why.

## Uninstall

```sh
openclaw skills info event-signup     # shows the Path of the installed skill
rm -rf ~/.openclaw/skills/event-signup
rm -rf ~/.claude/skills/signup        # /signup
```

Then delete the `event-signup` block from your agent's `AGENTS.md`. The queue folder
(`~/.openclaw-signup`, or your queue repo) is yours to keep or delete.

## Files

| File | What it is |
|---|---|
| `profile.example.md` | Template for your details. Copy to `profile.md`. |
| `skill/SKILL.md.tmpl` | The OpenClaw skill. `{{PROFILE}}` is replaced by your profile. |
| `skill/scripts/handoff.sh` | Queues a blocked event and prints the receipt the agent pastes. |
| `claude/signup/SKILL.md.tmpl` | The Claude Code `/signup` skill. |
| `queue/queue.py` | Reads and appends the queue log. |
| `queue/signupq` | The queue command both skills use; syncs it when the queue folder is a git clone. |
| `install.sh` | Builds and installs the OpenClaw skill, adds routing. bash + awk; uses `node` (which OpenClaw needs anyway) to read OpenClaw's JSON. |
| `install-claude-code.sh` | Installs `/signup` into Claude Code. |
| `tests/` | `bash tests/run.sh` runs every suite (needs python3, git, node, perl). |
