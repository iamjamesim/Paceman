# Identified pairing and removal

The source, desktop panels and iPhone code support named app installations and
removal from either side. The current iPhone pairing protocol requires connection
management support from the source. See [validation](validation.md) for test history.

## User behavior

- A new pairing reports an installation UUID, device name and platform. The UUID
  stays in the iPhone's device-local Keychain; the OS may report a generic name.
  Two apps with the same name remain separate connections.
- Scanning a fresh code for the same computer sends the existing credential as
  proof. The source rotates it in place, preserving the connection and pairing
  date. Old credentials stop working; push registers anew.
- Pairing sends the installation identity in the initial request. Saved phone
  connections remain in display order when another connection is removed.
- Each desktop row has its own persisted last-contact time. A diagnostic client
  or second phone cannot make another connection look current.
- Desktop: expand a connection, choose **Remove access…**, and confirm. This also
  works while sharing is off. Cancel is the initial keyboard selection; Escape
  cancels confirmation before collapsing details. Removal deletes this credential,
  its installation metadata and push destination. Watch pairing is unchanged.
- iPhone: **Remove computer** revokes its own credential before saving the
  remaining connections. If already revoked, removal still succeeds. If the
  computer is unreachable or secure storage fails, the app retains a retry path.
- A desktop-revoked phone shows **Access removed** on its next request, clears
  pending watch activity and local push setup, and offers reconnection by QR.

Access removal cannot recall an already received snapshot or an in-flight Apple
notification. Subsequent authenticated fetches fail, and removed push destinations
are no longer scheduled. This change does not add watch freshness/lease support.

## Setup and recovery

For alpha acceptance, start Omarchy from fresh source data and pair the current
iPhone app with a new QR code. `bash scripts/install-desktop.sh` installs the
code but preserves the installed database; rerunning it is not a data reset.
The installer no longer imports a checkout database. New pairings
require `clientManagement: 1` in the source response and an installation
identity in the request.
An old database containing unidentified clients fails source startup with a
clear reset instruction rather than silently keeping those credentials active.
Clear old phone connections explicitly during a development reset; reinstalling
the app alone is not the reset procedure.

An installation ID is not a secret or an authorization token. A matching claim
without the current credential cannot replace a pairing. The source returns 409
and leaves the new invitation usable. If the phone has lost its saved credential,
remove that connection on the desktop and scan a fresh code. This also recovers
an interrupted re-pair where the source rotated access but the phone did not
receive or securely save the replacement credential.

The source never infers ownership from a matching device name.

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
   on an installed iPhone simulator. Check pairing identity, connection storage,
   and removal failures.
2. Pair the current iPhone app with Omarchy and Mac. Verify both cards appear,
   activity reaches the correct card, and neither connection changes the other.
3. On the phone home screen, tap **Connect another computer** and scan a new QR
   from a computer that is already paired. The flow should say **Reconnect
   computer**. Verify one card remains in the same position, one desktop client
   row remains for that installation, and push setup re-registers.
4. Pair a second app installation, including a duplicate reported name. Verify
   independent contact times; removing one must preserve the other.
5. Expand the phone row on the desktop. Cancel removal once, then confirm removal
   of the test connection. Verify its next phone fetch shows **Access removed**,
   and its watch pairing remains intact. Reconnect by QR.
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
