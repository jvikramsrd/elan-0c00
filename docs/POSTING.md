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

## 3. Make this repo public and fill in the link — DONE

The comment now ends with:

```
Full write-up, the probing tool, and the patches:
<https://github.com/jvikramsrd/elan-0c00>
```

and the repo was made public with:

```sh
gh repo edit jvikramsrd/elan-0c00 --visibility public --accept-visibility-change-consequences
```

Don't post a link to a private repo — if the repo ever goes private again,
delete that line from the comment first.

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

## 5. Attach the patches

Two patches back claims in the comment. Both apply cleanly to the MR branch
head `11f0316d`, in this order:

| Patch | Backs | Verified by |
|---|---|---|
| `0003-elanmoc2-fix-double-free-of-retry-gerror.patch` | §1 double free | 6 rejected verifies on `0c00`, no coredump |
| `0004-elanmoc2-fix-memory-safety-in-user-id-parsing.patch` | §2 parsing bugs | AddressSanitizer, 3 crashes before / clean after |

Attach both, or paste them in fenced blocks. `0004` applies on top of `0003`;
it touches a different function, so either order works in practice, but offer
them in the order the report discusses them.

`patches/0002-elanmoc2-combined-wipe-fix-and-delete.patch` is **not** for
posting as-is — §3 raises the wipe-on-failed-delete behaviour as a design
question for @depau rather than a fix to merge, and 0002 also carries an
unrelated `delete` implementation. Let him answer the question first.

If @depau would rather keep !330 focused on the driver, both fixes stand on
their own against `master` once the driver lands — the comment already offers
that.

## 6. Optional: push a branch to your own fd.o fork

Attaching patches is enough. But a branch @depau can cherry-pick from is less
work for him, and it is the route `HACKING.md` describes for "an enterprising
hacker".

**Do not push this repo to gitlab.freedesktop.org.** That instance is
freedesktop.org's project infrastructure, not general code hosting, and a Rust
reimplementation is not an fd.o project — see `CONTRIBUTING-UPSTREAM.md`. The
only thing that belongs there is a fork of libfprint itself.

The branch is already prepared in the scratch clone at `work/libfprint`
(gitignored, so it is not part of this repo):

```
elanmoc2-memory-safety @ 8e4a86e6
  8e4a86e6 elanmoc2: Fix memory-safety bugs parsing the finger_info reply
  ac559668 elanmoc2: Fix double free of the retry GError in identify/verify
  11f0316d WIP add 0c7c          <- depau/elanmoc2, the MR !330 head
```

Both patches apply cleanly and the result compiles with no elanmoc2 warnings
(`meson setup build -Ddrivers=elanmoc2 && ninja -C build`).

To publish it:

1. Fork <https://gitlab.freedesktop.org/libfprint/libfprint> in the fd.o web UI.
   Forking works for any account; creating a *new* top-level project generally
   does not, and needs a request on `freedesktop/freedesktop`.
2. Add a credential — an SSH key, or a personal access token with `write_repo`
   — under your fd.o profile.
3. Push:

```sh
cd work/libfprint
git remote add mine git@gitlab.freedesktop.org:<your-fd.o-user>/libfprint.git
git push mine elanmoc2-memory-safety
```

Then link the branch from the MR comment. Say explicitly that it is based on
`11f0316d` and is *not* a merge request — you are not trying to supersede !330.

To rebuild the branch from scratch if `work/` is ever cleaned:

```sh
git checkout -B elanmoc2-memory-safety 11f0316d
git am ../../patches/0003-*.patch ../../patches/0004-*.patch
```

## Tone notes

The report leads with the double free on purpose. It is the finding that:

- is **not** `0c00`-specific, so it affects the maintainer's own `0c4c`
- is a memory-safety bug in a PAM-adjacent daemon running as root
- comes with a patch, a backtrace and a reproduction

That ordering is what makes this worth a maintainer's attention on a
five-year-old MR. Resist the urge to move your own device's problems to the top.

The report now *leads* with `0c00` working, because it does — enroll, commit,
identify, verify and delete all function, and PAM auth opens root sessions.
That is worth stating plainly to someone who has kept a driver alive for five
years without the hardware.

Two things you are deliberately *not* claiming, and shouldn't start claiming if
someone pushes back:

- that `ff 12` ignoring its slot index is a `0c00` quirk — you have one PID and
  no way to compare; the report asks him to check, it doesn't assert
- that anything reaches `ENROLL_WIPE_SENSOR` on `0c00` — §3 was a bug report
  and is now a design question, because the chain it rested on didn't hold

That retraction is in the report on purpose. Leaving it out and quietly
dropping the claim would be worse: he may have read the earlier framing in your
repo, and a contributor who marks their own retraction is easier to trust on
the findings that survived.
