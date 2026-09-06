# Posting to libfprint MR !330

Everything is drafted. What's left needs your hands: a sensor to touch and an
account only you can create.

## 1. Confirm the crash fix on your own hardware first

Don't post "I fixed it" until you've watched it not crash.

```sh
sudo ./scripts/verify-crash-test.sh
```

The script deliberately asks you for **wrong** fingers — rejections are what
exercise the buggy path. It counts fprintd coredumps before and after and
prints a verdict. Expect `PASSED`.

For a before/after, roll back to the unpatched library, run it again, watch it
say `FAILED`, then reinstall:

```sh
sudo cp /var/backups/elan-0c00/libfprint-2.so.2.0.0.distro-orig /usr/lib/libfprint-2.so.2.0.0
sudo ldconfig && sudo ./scripts/verify-crash-test.sh   # expect FAILED
sudo ./scripts/install-local.sh                        # back to patched
```

Remove the debug drop-in when you're done:

```sh
sudo rm -r /etc/systemd/system/fprintd.service.d && sudo systemctl daemon-reload
```

## 2. Get a freedesktop.org GitLab account

<https://gitlab.freedesktop.org/users/sign_in> — sign in with GitHub or Google;
it's a separate instance from gitlab.com and from your GitHub account.

## 3. Make this repo public and fill in the link

The comment ends with a placeholder:

```
Full write-up, the probing tool, and the patches:
<!-- add your repo link here, or delete this line -->
```

Either flip the repo public and paste the URL:

```sh
gh repo edit jvikramsrd/elan-0c00 --visibility public --accept-visibility-change-consequences
```

…or delete that line. Don't post a link to a private repo.

## 4. Post the comment

Read [`MR330-report.md`](MR330-report.md) end to end first. It goes out under
your name and it makes claims about someone else's code — you should agree with
every one of them.

Two things to re-run so you're posting output you generated yourself:

```sh
journalctl -b --since '7 days ago' | grep -iE 'fprintd|coredump'
coredumpctl info fprintd
```

Then paste the body of `MR330-report.md` (everything below the `---`, not the
"Review before posting" preamble) into a comment on:

<https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/330>

The web UI sits behind Anubis bot protection; a normal browser is fine, it's
only scripted access that struggles.

## 5. Attach the patch

`patches/0003-elanmoc2-fix-double-free-of-retry-gerror.patch` applies cleanly to
the MR branch head `11f0316d`. Attach it to the comment, or paste it in a fenced
block.

If @depau would rather keep !330 focused on the driver, the fix stands on its
own against `master` once the driver lands — the comment already offers that.

## Tone notes

The report leads with the double free on purpose. It is the finding that:

- is **not** `0c00`-specific, so it affects the maintainer's own `0c4c`
- is a memory-safety bug in a PAM-adjacent daemon running as root
- comes with a patch, a backtrace and a reproduction

That ordering is what makes this worth a maintainer's attention on a
five-year-old MR. Resist the urge to move your own device's problems to the top.

Two things you are deliberately *not* claiming, and shouldn't start claiming if
someone pushes back:

- that `0c00` works — it doesn't; identify still can't complete (§4)
- what `ff 12` should be replaced with — you didn't go opcode-hunting, and
  saying so is a strength, not a gap
