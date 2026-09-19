# Identified pairing and removal

The source, Omarchy panel and iPhone code support named app installations and
removal from either side. Linux protocol/desktop checks have run. Mac simulator
and signed device builds passed, along with all 21 iOS tests. The update is
installed on the existing iPhone, with successful foreground fetches; physical
pairing/removal acceptance below remains pending. See [validation](validation.md).

## User behavior

- A new pairing reports an installation UUID, device name and platform. The UUID
  stays in the iPhone's device-local Keychain; the OS may report a generic name.
  Two apps with the same name remain separate connections.
- Scanning a fresh code for the same computer sends the existing credential as
  proof. The source rotates it in place, preserving the connection and pairing
  date. Old credentials and streams stop working; push registers anew.
- Opening the updated iPhone app identifies its existing credential without
  re-pairing. Other older credentials stay **Unidentified connection**. We cannot
  infer which abandoned credentials belonged to the same physical phone.
- Each desktop row has its own persisted last-contact time. A diagnostic client
  or second phone cannot make another connection look current.
- Desktop: expand a connection, choose **Remove access…**, and confirm. This also
  works while sharing is off. Cancel is the initial keyboard selection; Escape
  cancels confirmation before collapsing details. Removal deletes this credential,
  its installation metadata and push destination. Watch pairing is unchanged.
- iPhone: **Remove computer** revokes its own credential before deleting the local
  pairing. If already revoked, removal still succeeds. If unreachable or the
  desktop is too old, the app keeps the pairing and explains how to retry.
- A desktop-revoked phone shows **Access removed** on its next request, clears
  pending watch activity and local push setup, and offers reconnection by QR.

Access removal cannot recall an already received snapshot or an in-flight Apple
notification. Subsequent authenticated fetches fail, and removed push destinations
are no longer scheduled. This change does not add watch freshness/lease support.

## Upgrade and recovery

Install the desktop first with `bash scripts/install-desktop.sh`, then build and
install the updated iPhone app. Existing credentials remain valid through the
desktop migration. Old apps can keep fetching but remain unidentified.

An installation ID is not a secret or an authorization token. A matching claim
without the current credential cannot replace a pairing. The source returns 409
and leaves the new invitation usable. If the phone has lost its saved credential,
remove that connection on the desktop and scan a fresh code. This also recovers
an interrupted re-pair where the source rotated access but the phone did not
receive or securely save the replacement credential.

When two unidentified records exist, open the updated app first. Its owned record
will become named; the others remain unidentified until explicitly removed.
There is no automatic merge or bulk revocation on upgrade.

The local CLI equivalent is:

```sh
pacemanctl status
pacemanctl remove-access --client-id UUID_FROM_STATUS
```

The command targets one local connection. Phone-side `DELETE /v1/client` always
derives its target from the caller's credential; it cannot remove another client.
See the [protocol](protocol.md) for request shapes and privacy boundaries.

## Mac and physical-device acceptance

1. Run `bash scripts/check-on-mac.sh`, then run the `AgentCompanion` scheme's tests
   on an installed iPhone simulator. Five new protocol tests cover legacy saved
   pairings, request identity/origin scoping, identification and removal failures.
2. Install on the already-paired iPhone. Open the app; verify its desktop row
   becomes named, activity still reaches the phone, and other old credentials
   remain untouched.
3. In Computer details, use **Reconnect with QR code** and scan a new desktop QR.
   Verify one row remains for that installation and push setup re-registers.
4. Pair a second app installation, including a duplicate reported name. Verify
   independent contact times; removing one must preserve the other.
5. Expand the phone row on the desktop. Cancel removal once, then confirm removal
   of the test connection. Verify its next phone fetch shows **Access removed**,
   its stream closes, and its watch pairing remains intact. Reconnect by QR.
6. Use **Remove computer** on the phone. Verify its desktop row and push
   destination disappear and the app returns to setup. Pair again.
7. Make the computer unreachable, attempt phone removal, and verify pairing is
   retained with a retry message. Restore connectivity and finish removal. Also
   check removal after desktop revocation (already-removed credential).
8. Verify desktop removal while Sharing is off and after restarting the source.
   Check long names, multiple rows, scrolling, keyboard confirmation and Escape.

Use test pairings for destructive checks. Do not interpret protocol fixtures or
desktop screenshots as physical iPhone/watch validation.

## Remove a watch from the phone

Watch detail offers Remove watch, using the same destructive action treatment as
Remove computer. Confirmation explains that updates and this phone's access stop;
the computer remains connected. AccessorySetupKit removes the selected accessory.
On success, the app stops reconnecting, clears that watch's pairing receipt,
preferences and displayed delivery timestamp, and leaves the detail page. A failed
request retains the pairing and presents a retryable error. Removal events for
other accessory IDs do not stop the selected watch.

This is not a watch factory reset or ownership transfer. Ownership credentials are
retained so the same phone can pair again; moving ownership to another phone is a
separate firmware/protocol flow.

Validation: simulator and signed device builds succeeded; existing 32 tests passed.
The paired detail layout was visually checked. Actual AccessorySetupKit removal
and re-pairing require physical acceptance; the user's watch was not unpaired as
part of this change.
