# openclaw-signup

An [OpenClaw](https://docs.openclaw.ai) skill that signs you up for events. Send your
agent an event link - Luma, Eventbrite, a Google Form, a hackathon portal, a waitlist -
and it opens the page in the OpenClaw browser, fills the form with your details and
submits it.

When it hits something only you can do (a captcha, an email code, a payment, a question
your profile doesn't answer), it stops and sends you the link, everything it filled in,
and what's left. It never guesses facts about you and never pays for anything.

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
                            Filled in so far: ... / Left for you: ..."
```

Your details live in `profile.md`, which never leaves your machine: `install.sh` copies
it into the skill file at install time, so the agent needs the browser tool but no file
access.

## Setup

You need a working OpenClaw (gateway running, an agent you can chat with) and Chrome,
Chromium, Brave or Edge on the machine OpenClaw runs on.

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

### 6. Try it

In your chat with the agent, send `/new` (so it starts a session with the new skill),
then send an event link on its own.

## Updating

- **Changed your profile?** Run `./install.sh` again.
- **New version of this repo?** `git pull`, then `./install.sh`.

Both are safe to repeat: the skill is replaced and the routing block is updated in place.

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

`./install.sh` itself refuses to run with an unedited template, a profile without a name
or email, or when OpenClaw doesn't show the skill as visible to the model, and says why.

## Uninstall

```sh
openclaw skills info event-signup     # shows the Path of the installed skill
rm -rf ~/.openclaw/skills/event-signup
```

Then delete the `event-signup` block from your agent's `AGENTS.md`.

## Files

| File | What it is |
|---|---|
| `profile.example.md` | Template for your details. Copy to `profile.md`. |
| `skill/SKILL.md.tmpl` | The skill. `{{PROFILE}}` is replaced by your profile. |
| `install.sh` | Builds the skill, installs it, adds routing. bash + awk; uses `node` (which OpenClaw needs anyway) to read OpenClaw's JSON. |
| `tests/test_install.sh` | Tests for `install.sh` against a fake `openclaw`. Run `bash tests/test_install.sh`. |
