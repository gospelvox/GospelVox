# Privacy Policy — GospelVox

**Effective Date:** 2 June 2026
**Last Updated:** 2 June 2026

This Privacy Policy explains how **Codedu Software Technologies**,
having its registered office at **COCO Group, Mukkadan Complex,
Infopark Smart City Short Road, Edachira, Kakkanad, Kochi, Kerala
682030, India** ("**GospelVox**", "**we**", "**us**", "**our**"), collects, uses, shares, retains, and protects
information about you when you use the GospelVox mobile application,
websites, and related services (collectively, the "**Platform**").

We are the **Data Fiduciary** under the Digital Personal Data
Protection Act, 2023 ("**DPDP Act**") for personal data we process
about Users in India, and the **Controller** under the UK GDPR and
EU GDPR for data of users in those jurisdictions. For California
residents we are the "**Business**" under the California Consumer
Privacy Act, 2018 ("**CCPA**").

By using the Platform you confirm you have read this Policy. Where
your jurisdiction requires consent, you give that consent by
proceeding to use the Platform.

---

## 1. Quick Summary

- We collect account, profile, payment-metadata, Session-content, and
  device data needed to operate the Platform.
- We use **Google Play's billing system** for in-app purchases,
  **Agora** for voice
  infrastructure, **OneSignal** and **Firebase Cloud Messaging** for
  notifications, **Google Sign-In** and **Apple Sign-In** for
  authentication, and **Google Firebase** as our backend host (data
  is stored in **Mumbai, India** — `asia-south1`).
- We do **not** sell your personal data.
- You can delete your account in-app at any time
  (Settings → Account → Delete Account) or by emailing
  **support@gospelvox.com**. Deletion completes within
  **30 days** of verification.
- India users: see Section 12 for the **Grievance Officer**'s
  contact, 48-hour acknowledgement, and 15-day resolution commitment.

## 2. Information We Collect

### 2.1 Information you provide

**Account and profile (all users):**

- Name, email address, phone number, profile photo, country/region,
  preferred language, gender (where you choose to provide it).

**Speaker (priest) registration data:**

- Full name, contact phone, email, profile photo.
- Denomination, sub-denomination, church name, diocese, location,
  years of experience, biography, languages spoken, areas of
  specialisation.
- **Identity proof** (government-issued ID document).
- **Ministry credential / ordination certificate.**
- **Bank account details:** account holder name, account number,
  IFSC code, bank name, branch name, account type (savings/current),
  and optionally a UPI ID — collected for paying out earnings.

**Session content:**

- **Chat messages** (text) you exchange during chat Sessions.
- **Voice audio** during voice Sessions — transmitted in real time
  through Agora. We do **not** record voice Sessions and do not
  retain voice content on our servers.
- **Reviews and ratings** you post about Speakers.
- **Matrimony profile** information (where you choose to use that
  feature).

**Payment information (Users):**

- Coin and other purchases initiated from the app. Payment is
  processed by **Google Play's billing system**; the actual card /
  UPI / net-banking credentials are entered on Google's screens and
  are **never received or stored by us**. We receive only the Google
  Play order ID, purchase token, product (SKU) identifier, purchase
  status, and amount.

**Communications:**

- Messages you send to our support, grievance officer, or other
  contact channels.

### 2.2 Information collected automatically

- **Device and usage data:** device model, OS version, app version,
  language settings, time zone, install/uninstall events, crash
  reports, performance metrics, in-app navigation events.
- **Connection data:** approximate IP address, network type
  (Wi-Fi / cellular).
- **Push notification tokens:** Firebase Cloud Messaging (FCM) and
  OneSignal player IDs.
- **Voice call quality metrics:** non-content metrics such as packet
  loss, jitter, latency, and connection state (used to diagnose call
  failures).

We do **not** use third-party trackers for advertising, and we do
not deploy Apple's App Tracking Transparency (ATT) tracking. Where
the SDKs we use (Crashlytics, OneSignal) collect device identifiers,
they are used for diagnostics and notification delivery only.

### 2.3 Information from third parties

- **Identity providers** (Google, Apple): your name, email, and a
  stable identifier, used solely to authenticate your account. We do
  not receive or store the password you use with your Google or
  Apple account.
- **Google Play / Google Payments**: the purchase-status, order ID,
  and purchase token needed to verify purchases, credit Coins, and
  reconcile transactions.

### 2.4 Permissions the app requests

| Permission | Why we ask |
|---|---|
| Microphone | To capture your voice during voice Sessions (Agora). |
| Camera | To take a profile photo and to capture document images during Speaker registration. |
| Photos / media | To pick a profile photo or document image from your gallery. |
| Notifications | To deliver incoming-Session alerts, message notifications, and important account updates via FCM / OneSignal. |
| Bluetooth | To route call audio to headsets / car systems during voice Sessions. |
| Network state | To detect connectivity and choose between Wi-Fi and cellular for Sessions. |
| Foreground service (microphone) | To keep a voice Session alive when you lock your screen or background the app. |

You can revoke any of these permissions through your device settings.
Some features will not work without the relevant permission.

## 3. How We Use Your Information

We use your information to:

1. **Provide the Platform** — create and maintain your account,
   verify Speakers, enable discovery, run Sessions, process Coin
   purchases, credit Speaker earnings, and process withdrawals.
2. **Communicate with you** — send Session and account notifications,
   transactional messages, security alerts, and (where you've opted
   in) updates about new features.
3. **Safety, integrity, and fraud prevention** — detect, prevent, and
   respond to fraud, abuse, harassment, and policy violations,
   including by reviewing reported Content within 24 hours.
4. **Comply with law** — meet our obligations under the Information
   Technology Act, 2000, the DPDP Act, payment regulations, tax
   laws (including TDS where applicable), and other applicable
   law.
5. **Improve the Platform** — analyse aggregated usage, fix crashes
   (Crashlytics), measure feature adoption, and improve reliability.
6. **Enforce our Terms** — investigate suspected breaches and take
   appropriate action.

### Legal bases (UK GDPR / EU GDPR users)

| Purpose | Legal basis |
|---|---|
| Provide the Platform (account, Sessions, payments) | Performance of a contract (Art. 6(1)(b)) |
| Speaker KYC / identity / bank verification | Legal obligation (Art. 6(1)(c)); legitimate interests (Art. 6(1)(f)) |
| Fraud prevention, security, abuse handling | Legitimate interests (Art. 6(1)(f)) |
| Promotional emails / push (if any) | Consent (Art. 6(1)(a)) — withdrawable any time |
| Crash and performance diagnostics | Legitimate interests (Art. 6(1)(f)) |

For DPDP Act purposes (India users), we process your personal data
based on your consent (given by using the Platform) and for "**certain
legitimate uses**" listed under the Act (including for the performance
of a contract, fraud prevention, compliance with law, and responding
to a medical emergency).

## 4. Sharing of Information — Data Processors and Sub-processors

We share your information only with the parties listed below, only
for the purposes described, and under contractual data-protection
obligations.

| Recipient | Purpose | Data shared | Country |
|---|---|---|---|
| **Google LLC / Google India Pvt Ltd** — Firebase Authentication | Sign-in, session tokens | Email, identity-provider ID, auth tokens | US / India |
| **Google LLC** — Cloud Firestore | Storing app data (user profile, Speaker profile, chat messages, transactions) | All structured app data | India (`asia-south1`, Mumbai) |
| **Google LLC** — Firebase Storage | Storing profile photos, ID proofs, certificates, message media | Uploaded files | India (`asia-south1`) |
| **Google LLC** — Cloud Functions | Server-side logic (payment verification, withdrawals, Session billing) | Request payload + caller identity | India (`asia-south1`) |
| **Google LLC** — Firebase Crashlytics | Crash and stability diagnostics | Device model, OS, app version, stack traces, non-personal install ID | US |
| **Google LLC** — Firebase Cloud Messaging (FCM) | Push notification delivery | FCM token, notification payload | US |
| **Google LLC** — Google Sign-In | Authentication | Email, name, profile picture URL, Google ID | US |
| **Apple Inc.** — Sign in with Apple | Authentication (iOS) | Email (or relay), name, Apple ID | US |
| **Google LLC** — Google Play Billing | In-app purchase processing and server-side verification | Google Play order ID, purchase token, product (SKU) ID, purchase status, amount | US / global |
| **Agora Lab, Inc.** | Real-time voice infrastructure for voice Sessions | Channel name, ephemeral user IDs, audio packets in transit (not retained by us) | US / global edge |
| **OneSignal, Inc.** | Push notification orchestration | OneSignal player ID, device model, OS, notification payload | US |

We do **not** sell or rent your personal data to advertisers, data
brokers, or any other third party for marketing. We do not share
identified personal data for cross-context behavioural advertising.

We may disclose information to courts, regulators, or law-enforcement
authorities where required by law, in response to a valid legal
process, or to protect the rights, property, or safety of Gospel
Vox, our users, or the public.

We may transfer your information as part of a merger, acquisition,
financing, reorganisation, or sale of all or part of our business,
subject to standard confidentiality protections.

## 5. International Transfers

Our primary data store is **Mumbai, India** (`asia-south1`). Some
sub-processors (Crashlytics, OneSignal, Agora, Apple Sign-In) process
data in the **United States** and other regions. Where personal data
of EU/UK users is transferred outside the EEA/UK, we rely on:

- the European Commission's **Standard Contractual Clauses (SCCs)**
  or the UK's International Data Transfer Addendum, and/or
- the recipient's certification under an applicable adequacy
  framework (e.g., the EU–US Data Privacy Framework, where
  applicable).

A copy of the relevant transfer mechanism is available from us on
request at **support@gospelvox.com**.

## 6. Retention

We keep your personal data only as long as we need it for the
purposes described in this Policy, or as required by applicable law.

| Category | Retention |
|---|---|
| User account & profile | While your account is active. Deleted within **30 days** of account deletion or our termination of your account. |
| Speaker profile, ID proof, certificate, bank details | While the Speaker account is active, plus the period required by Indian tax / KYC / anti-money-laundering law (typically **5–8 years**). |
| Chat messages | While both participants' accounts are active and for **12 months** thereafter, unless deletion is requested earlier. |
| Voice Session audio | **Not retained** (voice is transmitted in real time and is not recorded). |
| Wallet / payment / withdrawal transaction records | **8 years** from the financial year of the transaction, in line with Indian tax and bookkeeping law. |
| Crash and diagnostic logs | Up to **90 days**. |
| Support and grievance correspondence | **3 years** from closure of the matter. |

After the applicable retention period we will delete or irreversibly
anonymise the data. We may retain anonymised, non-identifying
aggregates indefinitely for analytics and Platform improvement.

## 7. Security

We use a combination of technical and organisational measures to
protect your personal data, including:

- TLS / HTTPS for all client–server traffic.
- Encryption at rest for data stored in Firestore, Firebase Storage,
  and Cloud Functions managed services.
- Encryption in transit for voice Sessions via Agora's transport
  encryption.
- Role-based access control on our Firebase project; access to
  production data is limited to authorised personnel.
- Server-authoritative payment verification — Coin balances are
  credited only after the Google Play purchase token is verified
  server-side with Google's servers.
- Periodic review of Firestore security rules and Cloud Functions
  permissions.

No system is perfectly secure. If we become aware of a personal-data
breach that is likely to result in a high risk to your rights and
freedoms, we will notify you and the relevant regulator(s) as
required by applicable law (e.g., within the timelines prescribed by
the DPDP Act and GDPR).

## 8. Your Rights

Subject to applicable law, you have the following rights:

### 8.1 All users

- **Access** — request a copy of the personal data we hold about you.
- **Correction** — ask us to correct inaccurate or incomplete data
  (most fields are editable in-app).
- **Deletion** — ask us to delete your data and account.
- **Withdraw consent** — where processing is based on consent, you
  may withdraw it at any time. Withdrawal does not affect the
  lawfulness of processing carried out before withdrawal.
- **Object to processing** based on legitimate interests, and
  **restrict** processing in certain circumstances.
- **Data portability** — receive a machine-readable copy of personal
  data you provided to us.
- **Nominate** another individual (DPDP) to exercise your rights in
  the event of your death or incapacity.
- **Complain** — lodge a complaint with the Data Protection Board of
  India (DPDP), the Information Commissioner's Office (UK), or your
  local supervisory authority (EU).

### 8.2 California residents (CCPA)

- Right to know what personal information we have collected, used,
  disclosed, or sold.
- Right to delete personal information.
- Right to correct inaccurate personal information.
- Right to opt-out of "sale" or "sharing" of personal information —
  **we do not sell or share personal information in the CCPA sense**.
- Right to non-discrimination for exercising any of these rights.

To exercise any of these rights, email **support@gospelvox.com**
from the email address linked to your account, or use the in-app
controls described in Section 10. We will respond within the timelines
required by applicable law (typically 30 days under GDPR; 45 days
under CCPA; the DPDP-Act timeline once notified).

## 9. Children's Privacy

The Platform is intended for users **18 years and above**. We do not
knowingly collect personal data from children. If you believe a
child has provided personal data to us, please contact
**support@gospelvox.com** and we will delete the data and
the associated account.

## 10. How to Delete Your Account

You may delete your account at any time:

1. **In-app:** Settings → Account → **Delete Account**. Confirm the
   deletion when prompted.
2. **By email:** write to **support@gospelvox.com** from the
   email associated with your account, with the subject line
   "**Account Deletion Request**".

What gets deleted:

- Your profile, photo, bio, preferences, and account record.
- Your chat messages, reviews, and matrimony profile (where present).
- Your push-notification tokens and device-bound identifiers.
- Your Wallet balance (unused Coins are forfeited on deletion).
- Speaker-side: bank details and KYC documents will be retained only
  for the period required by Indian tax / AML / KYC law, then
  deleted or anonymised.

What we may retain (and why):

- Financial transaction records (Coin purchases, Speaker earnings,
  withdrawals) for **8 years**, as required by Indian tax and
  bookkeeping law.
- Records needed to defend against, exercise, or establish legal
  claims.
- Aggregated, non-identifying analytics.

Deletion completes within **30 days** of verification, save for
records retained as above.

## 11. Cookies and Similar Technologies

The GospelVox mobile app does not use browser cookies. The SDKs we
use (Firebase, OneSignal, Agora) and the Google Play billing flow may
store small amounts of data locally on your device for session
continuity, crash reporting, and notification delivery. You can
clear this storage by clearing the app's data through your device
settings.

## 12. Grievance Officer (India)

In accordance with the Information Technology Act, 2000 and the
Information Technology (Reasonable Security Practices and Procedures
and Sensitive Personal Data or Information) Rules, 2011, and consistent
with the Information Technology (Intermediary Guidelines and Digital
Media Ethics Code) Rules, 2021, the Grievance Officer for the Platform
is:

- **Name:** Mr. Relin K Mathew
- **Designation:** Grievance Officer, GospelVox
- **Email:** Relin.m@outlook.com
- **Postal address:** Codedu Software Technologies, COCO Group,
  Mukkadan Complex, Infopark Smart City Short Road, Edachira,
  Kakkanad, Kochi, Kerala 682030, India
- **Phone:** +91 79070 18137 (Mon–Fri, 10:00–18:00 IST)

The Grievance Officer will:

- **Acknowledge** receipt of your complaint within **48 hours**.
- **Resolve** the complaint within **15 calendar days** of receipt,
  except where applicable law prescribes a shorter timeline.
- For complaints relating to Content depicting an individual in a
  sexual act or nudity, take all reasonable and practicable measures
  to remove or disable access to such Content within **24 hours**.

## 13. Data Protection Officer (where required)

If we become a "**Significant Data Fiduciary**" under the DPDP Act,
or where required by GDPR, we will appoint a Data Protection Officer
and update this Policy with their contact details.

## 14. Changes to This Policy

We may update this Policy from time to time. The "Last Updated" date
will reflect the latest version. We will notify you in the app or by
email about material changes. Your continued use of the Platform
after the changes take effect constitutes acceptance of the updated
Policy.

## 15. Contact Us

- **Privacy / data-protection enquiries:** support@gospelvox.com
- **General support:** support@gospelvox.com
- **Grievance Officer:** Relin.m@outlook.com
- **Postal address:** Codedu Software Technologies, COCO Group,
  Mukkadan Complex, Infopark Smart City Short Road, Edachira,
  Kakkanad, Kochi, Kerala 682030, India
