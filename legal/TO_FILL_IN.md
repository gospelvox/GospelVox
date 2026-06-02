# Legal pages — applied values & pre-launch checklist

**Status:** Drafts complete. No `[FILL: …]` placeholders remain in any
policy file. Both the markdown sources (`legal/*.md`) and the
rendered HTML (`public/*.html`) carry the same values.

This document records exactly what was applied so you can verify it
before deploying, and flags the four values I had to default because
you hadn't shared them. **Change any of these now if they're wrong —
once you submit to the stores, changing core business terms is a
versioned, slow process.**

---

## A. Operator identity (from you — verbatim)

| Field | Value |
|---|---|
| Legal entity name | **Codedu Software Technologies** |
| Registered / postal address | **COCO Group, Mukkadan Complex, Infopark Smart City Short Road, Edachira, Kakkanad, Kochi, Kerala 682030, India** |
| Support email | **support@gospelvox.com** |
| Privacy email (also used for data requests) | **support@gospelvox.com** (alias / same mailbox — set up a forwarder on your registrar/Workspace if not done) |
| Legal / IP-takedown email | **support@gospelvox.com** |
| Brand display name | GospelVox |
| Copyright line | © 2026 Codedu Software Technologies |

## B. Grievance Officer (from you — verbatim)

| Field | Value |
|---|---|
| Name | **Mr. Relin K Mathew** |
| Designation | Grievance Officer, GospelVox |
| Email | **Relin.m@outlook.com** |
| Postal address | Same as the operator address above |
| Phone | **+91 79070 18137** |
| Working hours | Mon–Fri, 10:00–18:00 IST |

## C. Document dates

| Field | Value |
|---|---|
| Effective Date | **2 June 2026** |
| Last Updated | **2 June 2026** |

Change both before publishing if the actual go-live date is later —
edit each of the four policy markdowns and the matching HTML files.

## D. Geography & payments

| Field | Value | Reason |
|---|---|---|
| Paid features available in | **India only** | Razorpay-only stack; Stripe / IAP not enabled yet |
| Currency | INR | Razorpay India settlement |
| GSTIN | Not currently registered | Document says GSTIN will be published when applicable |

## E. Dispute resolution

| Field | Value |
|---|---|
| Governing law | India |
| Arbitration seat / venue | **Kochi, Kerala, India** |
| Exclusive jurisdiction (subject to arbitration) | **Courts at Kochi, Kerala** |
| Language of arbitration | English |

## F. Business-economics defaults — ⚠️ **VERIFY BEFORE LAUNCH**

These four values weren't in what you shared, so I applied
industry-standard defaults. **If any of these is wrong, change it
now**: the values appear in the Terms, the Refund Policy, and what
you commit to in writing to the user.

| Field | Default applied | Where it appears | Status |
|---|---|---|---|
| **Speaker activation fee** | **₹999** (one-time, non-refundable) | T&C §5.3 | ⚠️ Confirm |
| **Platform commission** | **20%** of gross Session value | T&C §8.1 | ⚠️ Confirm |
| **Coin → INR rate (for Speaker withdrawals)** | **1 Coin = ₹1** | T&C §8.2 | ⚠️ Confirm |
| **Minimum withdrawal threshold** | **₹500** | T&C §8.3 | ⚠️ Confirm |

Other defaults you can change if needed:

| Field | Default | Where |
|---|---|---|
| Withdrawal settlement SLA | 5–7 business days | T&C §8.4, Help |
| Coin expiry on inactivity | 24 months | T&C §6.7 |
| Welcome offer | 100 Coins for ₹29 | T&C §6.5 (matches the existing default in [wallet_repository.dart](../lib/features/user/wallet/data/wallet_repository.dart)) |
| Chat-message retention after account closure | 12 months | Privacy Policy §6 |
| Session-failure refund SLA | 24–72 hours | Refund Policy §4.1 |

## G. Hosting URLs (this release)

Because gospelvox.com is not connected to Firebase Hosting yet, the
in-app links (and what you'll paste into the Play Console / App Store
Connect) point at the free Firebase domain:

| Surface | URL |
|---|---|
| Landing | https://gospelvox-a2208.web.app/ |
| Terms | https://gospelvox-a2208.web.app/terms |
| Privacy Policy | https://gospelvox-a2208.web.app/privacy-policy |
| Refund Policy | https://gospelvox-a2208.web.app/refund-policy |
| Account Deletion | https://gospelvox-a2208.web.app/delete-account |
| Help | https://gospelvox-a2208.web.app/help |

Updated in [lib/core/config/legal_urls.dart](../lib/core/config/legal_urls.dart).
Swap to https://gospelvox.com/... in a point release once you
connect the custom domain in Firebase Hosting.

---

# Pre-submission checklist (do this in order)

## Before deploying

- [ ] Read [legal/TERMS_AND_CONDITIONS.md](TERMS_AND_CONDITIONS.md)
      end-to-end. Confirm Section F defaults above.
- [ ] Read [legal/PRIVACY_POLICY.md](PRIVACY_POLICY.md).
- [ ] Read [legal/REFUND_POLICY.md](REFUND_POLICY.md).
- [ ] Read [legal/ACCOUNT_DELETION.md](ACCOUNT_DELETION.md).
- [ ] Make sure **support@gospelvox.com** actually receives mail
      (set up an MX record / Workspace / Zoho mailbox for the
      `gospelvox.com` domain). If you don't own gospelvox.com yet,
      register it now, or swap every `support@gospelvox.com` to an
      email you do own.
- [ ] Confirm **Relin.m@outlook.com** is monitored — the Grievance
      Officer's 48-hour ack SLA starts the moment a complaint lands
      there.

## Deploy

```
firebase deploy --only hosting
```

Expected output: a deploy URL plus the live URLs above. Open each one
in a browser before submitting to the stores — a 404 is the most
common cause of "policy URL not accessible" rejection.

## After deploying — store submission

### Apple App Store Connect

- [ ] App Privacy → Privacy Policy URL = `https://gospelvox-a2208.web.app/privacy-policy`
- [ ] App Privacy → fill in nutrition labels matching Privacy Policy §2
- [ ] App Information → Support URL = `https://gospelvox-a2208.web.app/help`
- [ ] App Information → Privacy Policy URL (same as above)
- [ ] Confirm Apple Sign-In is offered alongside Google Sign-In on iOS
- [ ] In-app account deletion path verified (Settings → Account → Delete Account)
- [ ] Confirm Section 17 of Terms (Apple EULA passthrough) is intact

### Google Play Console

- [ ] App content → Privacy policy URL = `https://gospelvox-a2208.web.app/privacy-policy`
- [ ] App content → Account deletion → Web URL = `https://gospelvox-a2208.web.app/delete-account`
- [ ] App content → Account deletion → Confirm both "delete account" and "delete data" are available in-app
- [ ] Data safety form → fill in matching Privacy Policy §2 and §4
- [ ] Store listing → Email = support@gospelvox.com
- [ ] Sensitive permissions (microphone, foreground service) → prominent disclosure shown before request in-app

### Razorpay merchant dashboard

- [ ] Settings → Profile → "Terms" URL = `https://gospelvox-a2208.web.app/terms`
- [ ] Settings → Profile → "Privacy" URL = `https://gospelvox-a2208.web.app/privacy-policy`
- [ ] Settings → Profile → "Refund" URL = `https://gospelvox-a2208.web.app/refund-policy`
- [ ] Settings → Profile → "Contact us" URL = `https://gospelvox-a2208.web.app/help`

---

# Things I still recommend you do (not document-related)

1. **Buy gospelvox.com if you haven't already** (~₹800/year on
   GoDaddy or Namecheap). The fact that you're already using
   `support@gospelvox.com` suggests you may already own it — if so,
   add it as a custom domain in Firebase Hosting and ship a point
   release that swaps the URLs in `legal_urls.dart`.

2. **Set up the support@gospelvox.com mailbox** if it isn't live yet.
   Google Workspace (₹125/mo) or Zoho Mail (free tier) — your call.

3. **Lawyer review** — one round with an Indian advocate familiar
   with IT Act intermediary rules and DPDP Act before submitting.
   The drafts are tight but a lawyer's signoff is still cheap
   insurance.

4. **Watch the Apple IAP angle** on first iOS review. If reviewers
   challenge the Razorpay flow as "in-app digital purchase needing
   IAP", point them at:
   - The Speaker is a real human with verified ID and ordination.
   - Sessions are person-to-person real-world services.
   - The framing in Terms §4 ("technology intermediary, sessions
     delivered by independent Speakers").

5. **Mental-health disclaimer surfacing** — consider adding a
   one-line "spiritual guidance only — not a substitute for
   medical/mental-health care" banner inside the app before a
   user starts their first Session. Strengthens the §14 disclaimer.
