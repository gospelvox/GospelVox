# Gospel Vox — Payment Migration Analysis

**Goal:** map every surface that touches Razorpay so the team can remove it cleanly and replace it with Google Play Billing (Android) + Apple In-App Purchase (iOS).

**Method:** read-only audit of `lib/`, `functions/src/`, `android/`, `ios/`, `legal/`, `public/`, and config files. Cross-referenced against [pubspec.yaml](pubspec.yaml), [pubspec.lock](pubspec.lock), [functions/package.json](functions/package.json), [firebase.json](firebase.json), [.gitignore](.gitignore).

**Disposition:** report only, no code changes applied.

---

## 1. PROJECT OVERVIEW

### What the app does

Gospel Vox is a Christian spiritual-consultation marketplace. Users buy in-app coins, then spend them per-minute on chat or voice sessions with approved priests/speakers. Priests can also host paid group "Bible sessions" via an external meeting link (Google Meet). The app is multi-role (user / priest / admin) and runs on Android + iOS. Today every paid surface uses Razorpay; priest payouts to bank are admin-processed offline against the priest wallet.

### Flutter / Dart versions

From [pubspec.yaml](pubspec.yaml) and [pubspec.lock](pubspec.lock):

- Dart SDK constraint: `^3.11.4`
- Flutter SDK constraint: `>=3.38.4` (lockfile `sdks` block)
- App version: `1.0.0+8` ([pubspec.yaml:4](pubspec.yaml#L4))

### Full dependency list (with flags)

**Payments — to remove:**
- `razorpay_flutter: any` → resolved `1.4.4` ([pubspec.lock:1355-1362](pubspec.lock#L1355-L1362))

**Firebase (KEEP — all in use):**
- `firebase_core`, `firebase_auth`, `cloud_firestore`, `firebase_storage`, `cloud_functions`, `firebase_crashlytics`, `firebase_messaging: ^16.2.0`

**Auth providers:**
- `google_sign_in`, `sign_in_with_apple`

**State / DI / routing:**
- `flutter_bloc`, `equatable` — state management
- `get_it`, `injectable` — service locator (manual registration in [lib/core/services/injection_container.dart](lib/core/services/injection_container.dart))
- `go_router` — routing
- Dev: `injectable_generator`, `build_runner`

**Realtime / device:**
- `agora_rtc_engine` — voice calls (used by per-minute billing economy — must keep)
- `permission_handler`
- `onesignal_flutter` — push (note: app also uses `firebase_messaging`; both ship)
- `flutter_local_notifications: ^21.0.0`
- `app_links` — deep links
- `connectivity_plus`
- `audioplayers: ^6.1.0` — ringtones
- `package_info_plus` — version display

**Misc UI / utilities:**
- `google_fonts`, `cached_network_image`, `shimmer`, `flutter_svg`, `font_awesome_flutter: ^11.0.0`, `shared_preferences`, `intl`, `image_picker`, `flutter_image_compress`, `dartz`, `uuid`, `url_launcher`, `share_plus`, `flutter_cache_manager`

**Cloud Functions (`functions/package.json`) — to flag:**
- `razorpay: ^2.9.6` ([functions/package.json:20](functions/package.json#L20)) — Node SDK; remove during migration
- `firebase-admin: ^13.0.2`, `firebase-functions: ^6.3.0`, `agora-token: ^2.0.5` — keep
- Node runtime: `20`

### Architecture & folder layout

Feature-first layout. Top-level tree (2–3 levels):

```
lib/
├── main.dart                              Firebase init + zoned print filter + runApp
├── firebase_options.dart                  generated
├── core/
│   ├── config/                            payment_config.dart, agora_config.dart
│   ├── constants/                         app_strings.dart
│   ├── router/                            app_router.dart (go_router)
│   ├── services/                          injection_container.dart (get_it),
│   │                                      razorpay_service.dart,
│   │                                      notification_service.dart,
│   │                                      connectivity_service.dart,
│   │                                      deep_link_service.dart,
│   │                                      ifsc_lookup_service.dart,
│   │                                      priest_incoming_request_service.dart,
│   │                                      ring_service.dart,
│   │                                      call_keep_alive_service.dart,
│   │                                      app_service.dart
│   ├── theme/                             app_colors / app_text_styles / app_spacing / app_theme / admin_colors
│   ├── utils/                             app_utils, bloc_observer, draft_storage
│   └── widgets/                           app_icons, app_loading_widget, app_version_text, ...
└── features/
    ├── auth/                              bloc/, data/, pages/, widgets/
    ├── user/
    │   ├── home/                          bloc/, data/, pages/, widgets/
    │   ├── wallet/                        bloc/wallet_cubit.dart, data/wallet_repository.dart,
    │   │                                  pages/wallet_page.dart, pages/payment_success_page.dart,
    │   │                                  widgets/payment_processing_overlay.dart,
    │   │                                  widgets/payment_failure_sheet.dart
    │   ├── bible/                         pages/bible_session_detail_page.dart, ...
    │   ├── session/                       chat + voice pages, session_request_cubit
    │   ├── sessions/                      chat_history_page
    │   ├── profile/                       settings, edit profile, about
    │   ├── matrimony/                     STUB (not shipping)
    │   └── notifications/
    ├── priest/
    │   ├── activation/                    pages/activation_paywall_page.dart,
    │   │                                  pages/activation_success_page.dart,
    │   │                                  bloc/activation_cubit.dart,
    │   │                                  data/activation_repository.dart
    │   ├── wallet/                        priest_wallet_page, bank_details_page,
    │   │                                  priest_wallet_cubit, priest_wallet_repository,
    │   │                                  data/wallet_models.dart
    │   ├── registration/                  multi-step priest application
    │   ├── dashboard/, session/, settings/, missed/, users/, bible/, profile/, reviews/, notifications/
    │   └── widgets/
    ├── admin/
    │   ├── settings/                      coin_pack_model.dart, coin_packs_repository.dart,
    │   │                                  settings_repository.dart, coin_packs_cubit.dart,
    │   │                                  settings_cubit.dart, pack_edit_sheet.dart,
    │   │                                  configuration_tab.dart
    │   ├── withdrawals/                   admin_withdrawal_model, admin_withdrawals_repository, cubit
    │   ├── speakers/, users/, sessions/, reports/, revenue/, matrimony/, dashboard/
    └── shared/
        ├── bloc/                          bible_session_cubit, chat_session_cubit,
        │                                  voice_call_cubit, session_history_cubit
        ├── data/                          bible_session_repository, bible_session_model,
        │                                  session_repository, session_model,
        │                                  session_history_repository
        ├── widgets/                       voice_call_view, chat_session_view, recharge_sheet
        └── pages/                         session_detail, session_history, chat_transcript

functions/
└── src/
    ├── index.ts                           barrel exports
    ├── config/constants.ts                REGION='asia-south1', PROJECT_ID
    ├── payments/                          createCoinOrder, verifyCoinPurchase,
    │                                      createActivationOrder, verifyActivationFee,
    │                                      verifyBibleSessionPayment
    ├── bible/                             createBibleSession, startBibleSession,
    │                                      completeBibleSession, payAndJoinBibleSession,
    │                                      onRegistrationWrite, notifyMeetLinkAdded,
    │                                      notifyBibleSessionCancellation,
    │                                      bibleSessionReminders, onBibleSessionRated
    ├── sessions/                          createSessionRequest, billingTick, endSession,
    │                                      sessionWatchdog, expireSessionRequest,
    │                                      generateAgoraToken, sendFollowUp,
    │                                      sendPriestMessage, onSessionTerminal,
    │                                      onSessionRated, replyToReview,
    │                                      missedRequestNotif, backfillPriestReviews,
    │                                      getPublicPriestReviews
    ├── priest/                            requestWithdrawal
    ├── admin/                             approveRejectPriest, onReportResolved
    ├── users/                             onUserCreated, notifyAvailableSubscribers
    └── notifications/                     sendPush
```

### State management / DI / routing / Firebase init

- **State management:** `flutter_bloc` (almost exclusively `Cubit` not `Bloc`). Examples: [WalletCubit](lib/features/user/wallet/bloc/wallet_cubit.dart), [ActivationCubit](lib/features/priest/activation/bloc/activation_cubit.dart), [PriestWalletCubit](lib/features/priest/wallet/bloc/priest_wallet_cubit.dart). Global `Bloc.observer = AppBlocObserver()` set in [main.dart:84](lib/main.dart#L84).
- **Dependency injection:** `get_it` with manual registration in [lib/core/services/injection_container.dart](lib/core/services/injection_container.dart). Convention is `registerLazySingleton` for repositories and `registerFactory` for cubits. `injectable_generator` is in dev deps but not actually invoked — registration is hand-written.
  - **`RazorpayService` is deliberately NOT registered** — see [injection_container.dart:167-171](lib/core/services/injection_container.dart#L167-L171). Each page constructs and disposes its own instance.
- **Routing:** `go_router` in [lib/core/router/app_router.dart](lib/core/router/app_router.dart). Role-based redirects via `_getUserRole` cache. Payment-related routes:
  - `/user/wallet` → `WalletPage`
  - `/user/payment-success` → `PaymentSuccessPage` (passes `{coins, newBalance}` via `extra`)
  - `/priest/activation` → `ActivationPaywallPage`
  - `/priest/activation-success` → `ActivationSuccessPage`
  - `/priest/wallet` → `PriestWalletPage`
  - `/priest/wallet/bank-details` → `BankDetailsPage`
- **Firebase initialisation:** [main.dart:49-51](lib/main.dart#L49-L51): `await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);` — using FlutterFire-generated `firebase_options.dart`. Project: `gospelvox-a2208` (see [firebase.json](firebase.json) and [functions/src/config/constants.ts:2](functions/src/config/constants.ts#L2)).

---

## 2. WHERE THINGS LIVE

### Wallet / coin balance storage

**User wallet (the "coin balance")**
- Firestore: `users/{uid}.coinBalance` — integer
- Read (one-shot): [wallet_repository.dart:29-35](lib/features/user/wallet/data/wallet_repository.dart#L29-L35) `getBalance(uid)`
- Read (stream): [wallet_repository.dart:21-26](lib/features/user/wallet/data/wallet_repository.dart#L21-L26) `watchBalance(uid)`
- Writes:
  - **Credit:** server-side only — [functions/src/payments/verifyCoinPurchase.ts:163-165](functions/src/payments/verifyCoinPurchase.ts#L163-L165) increments by `coins`
  - **Debit:** server-side only — [functions/src/sessions/billingTick.ts:103-105](functions/src/sessions/billingTick.ts#L103-L105) decrements by `rate`; [endSession.ts:80-103](functions/src/sessions/endSession.ts#L80-L103) and the partial-minute rollup [endSession.ts:140-149](functions/src/sessions/endSession.ts#L140-L149) also debit. Firestore rules deny client writes to `coinBalance` (per the audit notes — rules file not in scope here but client never writes it).

**Priest wallet**
- Firestore: `priests/{uid}.walletBalance`, `priests/{uid}.totalEarnings`, `priests/{uid}.totalWithdrawn` — all integers in INR (₹)
- Writes (all server-side):
  - Credit per-minute earnings: [billingTick.ts:107-114](functions/src/sessions/billingTick.ts#L107-L114) and [endSession.ts:83-86](functions/src/sessions/endSession.ts#L83-L86) / [endSession.ts:142-149](functions/src/sessions/endSession.ts#L142-L149)
  - Credit Bible session earnings: [payAndJoinBibleSession.ts:320-339](functions/src/bible/payAndJoinBibleSession.ts#L320-L339), [verifyBibleSessionPayment.ts:274-293](functions/src/payments/verifyBibleSessionPayment.ts#L274-L293)
  - Debit on withdrawal: [requestWithdrawal.ts:196-201](functions/src/priest/requestWithdrawal.ts#L196-L201) (uses `increment(-amount)` plus `totalWithdrawn += amount`)

**Global ledger**
- Firestore collection: `wallet_transactions` — single appendable ledger used by both buyer and priest views.
- Per-row shape (server-written; readers gracefully handle missing keys):
  - `userId` (string; `__platform__` sentinel for commission rows)
  - `type` — one of: `"purchase"` (coin top-up), `"session_charge"` (per-minute debit, negative), `"activation_fee"` (priest activation debit/audit), `"bible_session"` (user side, paid for a Bible session), `"bible_session_earning"` (priest side, credit), `"bible_session_commission"` (`__platform__` row), `"withdrawal"` (priest debit), `"refund"`
  - `coins` (signed int) OR `amountPaid` (positive int) depending on row type — see [wallet_models.dart:42](lib/features/priest/wallet/data/wallet_models.dart#L42) which deserialises `coins`; the user-side purchase rows use `amountPaid`
  - `paymentId`, `orderId`, `packId`, `sessionId`, `withdrawalId`, `description` — optional context
  - `createdAt` — server timestamp
- Used as the **idempotency / replay defence** key across all 3 paid flows: every payment CF runs `where('paymentId', '==', razorpayPaymentId).limit(1)` before crediting (see e.g. [verifyCoinPurchase.ts:65-77](functions/src/payments/verifyCoinPurchase.ts#L65-L77)).

### Coin packs / product IDs / prices

**Storage location:** Firestore subcollection `app_config/coin_packs/packs/{packId}`.

**Document fields** ([coin_pack_model.dart:1-67](lib/features/admin/settings/data/coin_pack_model.dart#L1-L67)):
- `coins` (int), `price` (int — INR), `label` (string), `order` (int), `isPopular` (bool), `isActive` (bool)
- Doc id convention: `pack_<coins>` ([coin_packs_repository.dart:22](lib/features/admin/settings/data/coin_packs_repository.dart#L22))
- `pricePerCoin`, `oldPrice = ceil((coins*1.5)/100)*100`, `discountPercent` — **computed client-side** on the model (not stored).

**The actual values:** packs are NOT seeded in code — they are entered manually in the **admin Settings UI** ([lib/features/admin/settings/widgets/pack_edit_sheet.dart](lib/features/admin/settings/widgets/pack_edit_sheet.dart)). The Wallet page loads them via `WalletRepository.getCoinPacks()` ([wallet_repository.dart:50-68](lib/features/user/wallet/data/wallet_repository.dart#L50-L68)) with a 15-minute in-memory cache.

**Welcome offer (special pack):** NOT in the `packs` subcollection. Lives on `app_config/settings`:
- `welcomeOfferCoins` (int, default 100)
- `welcomeOfferPrice` (int, default 29)

Treated by the CF as a synthetic `packId == 'welcome_offer'` — guarded by a one-purchase-per-user check ([createCoinOrder.ts:48-85](functions/src/payments/createCoinOrder.ts#L48-L85)).

**No hard-coded SKU table exists today** — neither in Dart nor in TypeScript. Pack IDs are dynamic. This matters for the IAP migration because Google Play and App Store require a closed, pre-declared product set in the consoles.

### App config / settings

Firestore document: `app_config/settings`. Fields used:
- `priestActivationFee` (int, ₹, default 500) — [createActivationOrder.ts:65-71](functions/src/payments/createActivationOrder.ts#L65-L71), [activation_repository.dart:47](lib/features/priest/activation/data/activation_repository.dart#L47)
- `welcomeOfferCoins`, `welcomeOfferPrice` — see above
- `chatRatePerMinute` (int coins, default 10) — [createSessionRequest.ts:123](functions/src/sessions/createSessionRequest.ts#L123)
- `voiceRatePerMinute` (int coins, default 15) — [createSessionRequest.ts:125](functions/src/sessions/createSessionRequest.ts#L125)
- `commissionPercent` (int, default 20) — chat/voice split
- `bibleCommissionPercent` (int, default 20) — Bible session split, [payAndJoinBibleSession.ts:217-232](functions/src/bible/payAndJoinBibleSession.ts#L217-L232)
- `minSessionMinutes` (int, default 5) — affordability gate
- `minWithdrawalAmount` (int, default 100) — [requestWithdrawal.ts:92-95](functions/src/priest/requestWithdrawal.ts#L92-L95)
- `updatedAt` — server timestamp

Read by clients via [settings_repository.dart](lib/features/admin/settings/data/settings_repository.dart); written by admin via the same file plus `coin_packs_repository.dart` for pack rows. Firestore rules (per audit notes) gate writes to admin role.

---

## 3. CURRENT PAYMENT SYSTEM (RAZORPAY) — EXHAUSTIVE MAP

### 3.1 Every file that mentions Razorpay (production code only; `node_modules` excluded)

**Flutter client:**

| File | Role |
|---|---|
| [pubspec.yaml:39](pubspec.yaml#L39) | Declares `razorpay_flutter: any` |
| [pubspec.lock:1355-1362](pubspec.lock#L1355-L1362) | Resolved to v1.4.4 |
| [lib/core/config/payment_config.dart](lib/core/config/payment_config.dart) | `PaymentConfig.razorpayKeyId` (via `String.fromEnvironment('RAZORPAY_KEY_ID', defaultValue: 'rzp_test_…')`), `companyName`, `companyDescription`, `toPaise()`, `checkoutThemeHex`. Hard-coded test key fallback. |
| [lib/core/services/razorpay_service.dart](lib/core/services/razorpay_service.dart) | Wraps `Razorpay` SDK. Two entrypoints: `openCheckout()` (uses pre-created `order_id` + signature flow) and `openCheckoutWithoutOrder()` (direct-amount, used only by Bible pay-and-join). Includes an ASCII-only `_sanitizeDescription` to dodge Razorpay's "description contains invalid characters" error. |
| [lib/features/user/wallet/pages/wallet_page.dart](lib/features/user/wallet/pages/wallet_page.dart) | Coin purchase trigger UI. Owns its own `RazorpayService` instance; `_onPaymentSuccess` / `_onPaymentFailure` / `_onExternalWallet`. Implements anti-double-charge logic (`_lastErrorWasAfterCapture`, `_verifyInFlight`). |
| [lib/features/user/wallet/bloc/wallet_cubit.dart](lib/features/user/wallet/bloc/wallet_cubit.dart) | `createOrder(packId)` and `verifyAndCreditPurchase(...)` orchestration. Doesn't import Razorpay itself — it passes the three Razorpay-returned strings (`razorpayPaymentId/OrderId/Signature`) into the CF. |
| [lib/features/user/wallet/data/wallet_repository.dart](lib/features/user/wallet/data/wallet_repository.dart) | Callable-CF invocations: `createCoinOrder` and `verifyCoinPurchase`. Defines `CoinOrder` DTO with `orderId/amountPaise/coins/priceRupees`. |
| [lib/features/user/wallet/widgets/payment_processing_overlay.dart](lib/features/user/wallet/widgets/payment_processing_overlay.dart) | Full-screen overlay between Razorpay-close and CF-credit. Comment-only references to Razorpay. |
| [lib/features/user/wallet/widgets/payment_failure_sheet.dart](lib/features/user/wallet/widgets/payment_failure_sheet.dart) | Modal bottom sheet shown on Razorpay failure or post-capture verify failure. Returns `bool?` indicating whether to reopen Razorpay (suppressed in post-capture path). |
| [lib/features/priest/activation/pages/activation_paywall_page.dart](lib/features/priest/activation/pages/activation_paywall_page.dart) | Priest activation trigger UI. Same pattern as wallet — owns its own `RazorpayService`, handles success/failure, has a `_PaymentStuckScreen` terminal state for post-capture verify failures (no retry button to avoid double-charge). |
| [lib/features/priest/activation/bloc/activation_cubit.dart](lib/features/priest/activation/bloc/activation_cubit.dart) | `loadFee()`, `createOrder()`, `verifyPayment(...)`. Sets `afterCapture: true` on CF errors during verify. |
| [lib/features/priest/activation/data/activation_repository.dart](lib/features/priest/activation/data/activation_repository.dart) | Callable invocations: `createActivationOrder`, `verifyActivationFee`. Defines `ActivationOrder` DTO. |
| [lib/features/priest/activation/pages/activation_success_page.dart](lib/features/priest/activation/pages/activation_success_page.dart) | Comment-only reference to Razorpay (`PopScope` rationale). |
| [lib/features/user/bible/pages/bible_session_detail_page.dart](lib/features/user/bible/pages/bible_session_detail_page.dart) | "Pay & Join" trigger for live Bible sessions (`_payAndJoin` at line 212). Uses `openCheckoutWithoutOrder` (direct-amount). |
| [lib/features/shared/data/bible_session_repository.dart](lib/features/shared/data/bible_session_repository.dart) | CF invocations: `verifyBibleSessionPayment` (legacy) and `payAndJoinBibleSession` (current). |
| [lib/features/shared/widgets/recharge_sheet.dart](lib/features/shared/widgets/recharge_sheet.dart) | Mid-session top-up bottom sheet. Calls `createCoinOrder` + `verifyCoinPurchase` itself (does NOT route through `WalletCubit`). Used from voice/chat low-balance prompts and the 5-minute pre-session affordability gate. |
| [lib/features/shared/widgets/voice_call_view.dart](lib/features/shared/widgets/voice_call_view.dart) | Comment-only Razorpay reference (rationale for mid-call recharge sheet behaviour). |
| [lib/features/user/session/pages/voice_call_page.dart](lib/features/user/session/pages/voice_call_page.dart) | Searched-positive (likely comments / mid-call recharge hook). |
| [lib/features/priest/wallet/pages/bank_details_page.dart](lib/features/priest/wallet/pages/bank_details_page.dart) | Comment only — IFSC lookup uses ifsc.razorpay.com. **Not a payment integration.** |
| [lib/features/priest/wallet/pages/priest_wallet_page.dart](lib/features/priest/wallet/pages/priest_wallet_page.dart) | Comment only ("Razorpay X fee" reference in a placeholder). No actual integration. |
| [lib/features/priest/wallet/data/wallet_models.dart](lib/features/priest/wallet/data/wallet_models.dart) | Comment only ("Razorpay X, NEFT/IMPS routing"). |
| [lib/core/services/ifsc_lookup_service.dart](lib/core/services/ifsc_lookup_service.dart) | Calls the **free public** `https://ifsc.razorpay.com/<IFSC>` directory. NO key, NO payment. Pure metadata utility for the priest bank-details form. |
| [lib/core/services/injection_container.dart:167-171](lib/core/services/injection_container.dart#L167-L171) | Comment explaining why `RazorpayService` is intentionally NOT a singleton. |
| [AUDIT_REPORT.md](AUDIT_REPORT.md) | Internal audit doc — Razorpay mentioned in narrative. |

**Cloud Functions (TypeScript source + compiled output):**

| File | Role |
|---|---|
| [functions/package.json:20](functions/package.json#L20) | Declares `razorpay: ^2.9.6` dependency |
| [functions/src/config/constants.ts](functions/src/config/constants.ts) | Comment-only Razorpay reference (legacy `functions:config:set` instructions) |
| [functions/src/index.ts](functions/src/index.ts) | Exports the five live payment CFs + comment noting `activatePriestAccount` is an orphan because activation runs through `verifyActivationFee` |
| [functions/src/payments/createCoinOrder.ts](functions/src/payments/createCoinOrder.ts) | Creates a Razorpay `Order` for coin packs. Pins authoritative price from Firestore. |
| [functions/src/payments/verifyCoinPurchase.ts](functions/src/payments/verifyCoinPurchase.ts) | HMAC-SHA256 signature check + `orders.fetch` cross-check + dedupe + credit. |
| [functions/src/payments/createActivationOrder.ts](functions/src/payments/createActivationOrder.ts) | Razorpay order for the priest activation fee. |
| [functions/src/payments/verifyActivationFee.ts](functions/src/payments/verifyActivationFee.ts) | HMAC check + `orders.fetch` + flip `priests/{uid}.isActivated`. |
| [functions/src/payments/verifyBibleSessionPayment.ts](functions/src/payments/verifyBibleSessionPayment.ts) | LEGACY direct-amount flow. `payments.fetch` + capture-if-authorized + credit. Still exported but the live UI no longer invokes it (Bible flow now uses `payAndJoinBibleSession`). |
| [functions/src/bible/payAndJoinBibleSession.ts](functions/src/bible/payAndJoinBibleSession.ts) | NEW direct-amount Bible flow. `payments.fetch` + capture-if-authorized + flip registration + credit priest + commission split. |
| [functions/src/priest/requestWithdrawal.ts](functions/src/priest/requestWithdrawal.ts) | **DOES NOT USE RAZORPAY.** Writes a `withdrawals/{clientRequestId}` doc in `pending` status; admin processes the payout off-platform. The Razorpay X branding referenced elsewhere is aspirational, not wired. |
| `functions/lib/**/*.js` + `*.js.map` | Compiled output (TypeScript build artifact) — regenerated by `npm run build` on deploy. Same coverage as the `.ts` files above. |

**Android:**
- [android/app/src/main/AndroidManifest.xml:183-192](android/app/src/main/AndroidManifest.xml#L183-L192) — Impeller disabled with rationale "Razorpay's checkout WebView renders incorrectly on Samsung One UI". No BILLING permission. No Razorpay-specific manifest entry beyond the rendering workaround.

**Legal / public site (text content only):**
- [legal/TERMS_AND_CONDITIONS.md](legal/TERMS_AND_CONDITIONS.md), [legal/PRIVACY_POLICY.md](legal/PRIVACY_POLICY.md), [legal/REFUND_POLICY.md](legal/REFUND_POLICY.md), [legal/ACCOUNT_DELETION.md](legal/ACCOUNT_DELETION.md), [legal/TO_FILL_IN.md](legal/TO_FILL_IN.md)
- [public/terms.html](public/terms.html), [public/privacy-policy.html](public/privacy-policy.html), [public/refund-policy.html](public/refund-policy.html), [public/help.html](public/help.html), [public/delete-account.html](public/delete-account.html)

All contain literal references to "Razorpay Software Private Limited" as the payment processor. Will need editorial updates as part of the migration.

### 3.2 Package versions and key locations

| Side | Package | Version |
|---|---|---|
| Flutter | `razorpay_flutter` | 1.4.4 ([pubspec.lock:1362](pubspec.lock#L1362)) |
| Node CF | `razorpay` | ^2.9.6 → resolved per lockfile ([functions/package.json:20](functions/package.json#L20)) |

**Where the keys live (locations, not values):**

- **Client (public key id only):** [lib/core/config/payment_config.dart:49-52](lib/core/config/payment_config.dart#L49-L52) — `String.fromEnvironment('RAZORPAY_KEY_ID', defaultValue: 'rzp_test_Sfi6ecRbnuqcfW')`. Production builds inject the live key via `--dart-define=RAZORPAY_KEY_ID=…`. **The test key is committed in source.**
- **Server (secret):** `functions/.env` — gitignored ([.gitignore:52-54](.gitignore#L52-L54)). The CFs read `process.env.RAZORPAY_KEY_ID` and `process.env.RAZORPAY_KEY_SECRET` (every payment CF: [createCoinOrder.ts:32-33](functions/src/payments/createCoinOrder.ts#L32-L33), [verifyCoinPurchase.ts:52-53](functions/src/payments/verifyCoinPurchase.ts#L52-L53), [createActivationOrder.ts:55-56](functions/src/payments/createActivationOrder.ts#L55-L56), [verifyActivationFee.ts:50-51](functions/src/payments/verifyActivationFee.ts#L50-L51), [verifyBibleSessionPayment.ts:50-51](functions/src/payments/verifyBibleSessionPayment.ts#L50-L51), [payAndJoinBibleSession.ts:71-72](functions/src/bible/payAndJoinBibleSession.ts#L71-L72)). The header comment in `payment_config.dart` documents migrating the secret to Firebase Secrets Manager via `firebase functions:secrets:set RAZORPAY_KEY_SECRET` but this **has not been done yet** — the secret currently still lives in `.env`.
- There is **no Razorpay webhook** configured. Reconciliation is done synchronously inside `verifyCoinPurchase` / `verifyActivationFee` (HMAC) or `payments.fetch` (Bible). No webhook URL is registered with Razorpay; no inbound webhook handler exists in `functions/src/`.

### 3.3 The three paid flows — step by step

#### (a) Coin top-up (user buys coins)

**Trigger screens:**
- Main wallet: [lib/features/user/wallet/pages/wallet_page.dart](lib/features/user/wallet/pages/wallet_page.dart) — pack grid + "Proceed to Pay ₹X" button at line 1372; welcome-offer card at line 600
- Mid-session top-up: [lib/features/shared/widgets/recharge_sheet.dart](lib/features/shared/widgets/recharge_sheet.dart) — bottom sheet invoked from chat/voice low-balance prompts and the pre-session 5-minute affordability gate

**Step-by-step flow (main wallet path):**
1. User taps `_proceedToPay` or `_claimWelcomeOffer` ([wallet_page.dart:268-300](lib/features/user/wallet/pages/wallet_page.dart#L268-L300))
2. `_startPurchase(pack, description)` ([wallet_page.dart:210-266](lib/features/user/wallet/pages/wallet_page.dart#L210-L266)):
   - Sets `_isPaymentInProgress = true` to lock the button
   - Force-refreshes Firebase ID token (`user.getIdToken(true)`) — prevents stale-token failures on Samsung's aggressive background freeze
   - `cubit.createOrder(packId)` → `WalletCubit.createOrder` → `WalletRepository.createCoinOrder` → callable `createCoinOrder` CF with payload `{packId}`
3. CF [createCoinOrder.ts](functions/src/payments/createCoinOrder.ts):
   - Re-reads the pack price from Firestore (`app_config/coin_packs/packs/{packId}`) or the welcome-offer values from `app_config/settings`. One-time-claim check for `welcome_offer`.
   - `razorpay.orders.create({amount: priceRupees*100, currency:'INR', receipt:'cp_<uid10>_<base36ts>', notes:{uid, packId, coins}})`
   - Returns `{orderId, amount, currency, keyId, coins, priceRupees}`
4. Client opens Razorpay sheet via `RazorpayService.openCheckout(...)` — passes `razorpayOrderId`, `amountInPaise`, sanitized `description`, user email/name/phone, theme color `#6B3A2A`. UPI is offered by Razorpay's built-in sheet; `external.wallets` deliberately omitted ([razorpay_service.dart:85-95](lib/core/services/razorpay_service.dart#L85-L95)).
5. User pays. Razorpay's `EVENT_PAYMENT_SUCCESS` fires with `{paymentId, orderId, signature}`. Handler `_onPaymentSuccess` ([wallet_page.dart:92-133](lib/features/user/wallet/pages/wallet_page.dart#L92-L133)) sets `_verifyInFlight=true` and calls `cubit.verifyAndCreditPurchase(...)`.
6. CF [verifyCoinPurchase.ts](functions/src/payments/verifyCoinPurchase.ts):
   - Idempotency: `wallet_transactions.where('paymentId','==',razorpayPaymentId).limit(1)` — if found, return existing balance ([verifyCoinPurchase.ts:65-77](functions/src/payments/verifyCoinPurchase.ts#L65-L77))
   - HMAC: `crypto.createHmac('sha256', keySecret).update(`${orderId}|${paymentId}`).digest('hex')`, compared with `timingSafeEqual` ([verifyCoinPurchase.ts:83-100](functions/src/payments/verifyCoinPurchase.ts#L83-L100))
   - Cross-check: `razorpay.orders.fetch(orderId)` — confirms `status === 'paid'`, `notes.packId === packId`, extracts `notes.coins` ([verifyCoinPurchase.ts:107-144](functions/src/payments/verifyCoinPurchase.ts#L107-L144))
   - Batched writes:
     - `users/{uid}.coinBalance += coins`
     - `wallet_transactions` row: `{userId, type:'purchase', paymentId, orderId, packId, coins, amountPaid, createdAt}`
     - `notifications` row: `{type:'coins_purchased', title:'Coins Added', body, isRead:false}`
   - Best-effort push via `sendPushNotification`
7. CF returns `{newBalance, alreadyProcessed}`. Cubit emits `WalletPurchaseSuccess`, page navigates to `/user/payment-success`, cubit awaits `reloadAfterPurchase(uid)` so the wallet body is repopulated before the user dismisses the success screen.

**After-success Firestore writes:** **server-side only** (CF Admin SDK). Client never touches `coinBalance` directly.

**Mid-session recharge variant ([recharge_sheet.dart](lib/features/shared/widgets/recharge_sheet.dart)):** same callables (`createCoinOrder` + `verifyCoinPurchase`), but talks to `WalletRepository` directly without involving `WalletCubit` — the sheet owns its own success/failure handlers and pops `true` on success so the calling page can refresh its local balance state.

#### (b) Priest activation (one-time ₹500 fee unlocks earning)

**Trigger screen:** [lib/features/priest/activation/pages/activation_paywall_page.dart](lib/features/priest/activation/pages/activation_paywall_page.dart). Route `/priest/activation`. Reached after admin approval (`priests/{uid}.status === 'approved'` AND `isActivated !== true`).

**Step-by-step flow:**
1. Cubit auto-loads `priestActivationFee` via `ActivationRepository.getActivationFee()` ([activation_repository.dart:42-48](lib/features/priest/activation/data/activation_repository.dart#L42-L48)) — reads `app_config/settings.priestActivationFee` with a 500 fallback.
2. Priest taps "Activate for ₹500". `_proceedToPay` ([activation_paywall_page.dart:181-243](lib/features/priest/activation/pages/activation_paywall_page.dart#L181-L243)):
   - `_payTapLocked = true`, haptic, validate `ActivationReady` state
   - Force-refresh Firebase ID token
   - `cubit.createOrder()` → `ActivationRepository.createOrder` → callable `createActivationOrder` (no payload)
3. CF [createActivationOrder.ts](functions/src/payments/createActivationOrder.ts):
   - Validates `priests/{uid}.status === 'approved'` and `isActivated !== true`
   - Reads authoritative fee from `app_config/settings.priestActivationFee` (default 500)
   - `razorpay.orders.create({amount, currency:'INR', receipt:'act_<uid10>_<base36ts>', notes:{uid, purpose:'priest_activation'}})`
   - Returns `{orderId, amount, currency, keyId, priceRupees}`
4. Client opens Razorpay sheet via `RazorpayService.openCheckout(...)` with description `'Gospel Vox Speaker Activation'`
5. On `_onPaymentSuccess` ([activation_paywall_page.dart:114-140](lib/features/priest/activation/pages/activation_paywall_page.dart#L114-L140)), the cubit emits `ActivationVerifying`, page shows full-screen `_VerificationOverlay`, calls `cubit.verifyPayment(...)`.
6. CF [verifyActivationFee.ts](functions/src/payments/verifyActivationFee.ts):
   - Re-reads priest doc; returns `{alreadyActivated:true}` early if already activated
   - Idempotency on `wallet_transactions.where('paymentId', '==', …)`
   - HMAC-SHA256 signature check (same algorithm as coin purchase)
   - `razorpay.orders.fetch(orderId)` cross-check: `status==='paid'`, `notes.uid===uid`, `notes.purpose==='priest_activation'`
   - Amount match against current `priestActivationFee`
   - Batched writes:
     - `priests/{uid}`: `isActivated=true`, `activatedAt=serverTimestamp`, `activationPaymentId=razorpayPaymentId`
     - `users/{uid}.isActivated = true` (mirror)
     - `wallet_transactions`: `{userId, type:'activation_fee', paymentId, orderId, amountPaid, description}`
     - `notifications`: `{type:'account_activated', title:'Account Activated!', body, isRead:false}`
   - Push via `sendPushNotification`
7. Cubit emits `ActivationSuccess`, page navigates to `/priest/activation-success`. On error the page swaps to `_PaymentStuckScreen` (no retry button, "Copy payment reference" + Contact Support actions) — the cubit sets `afterCapture: true` for any CF error path.

**After-success Firestore writes:** **server-side only.** The `priests/{uid}.isActivated` flag is written by the CF.

#### (c) Bible session unlock (user pays to join a live group session)

**Trigger screen:** [lib/features/user/bible/pages/bible_session_detail_page.dart](lib/features/user/bible/pages/bible_session_detail_page.dart) — the "Pay & Join" button on a `status === 'live'` Bible session detail.

**Two CFs exist; only the new one is wired from the live UI today:**
- New (current): `payAndJoinBibleSession` — direct-amount Razorpay, no pre-created order
- Legacy (still exported, no client caller in the new Bible flow): `verifyBibleSessionPayment` — same direct-amount shape

**Step-by-step flow (current path):**
1. User taps the Pay & Join button; `_payAndJoin()` runs ([bible_session_detail_page.dart:212-247](lib/features/user/bible/pages/bible_session_detail_page.dart#L212-L247))
   - Validates session is live + has a meeting link
   - `_razorpayService.openCheckoutWithoutOrder(amountInPaise: session.price * 100, description:'Bible Session - <title>', notes:{sessionId, uid})` — **NO server-side order created**. Description uses a plain hyphen because Razorpay rejects em-dashes (rationale at [bible_session_detail_page.dart:231-237](lib/features/user/bible/pages/bible_session_detail_page.dart#L231-L237)).
2. Razorpay returns `{paymentId, orderId?, signature?}` — `orderId` and `signature` may be empty in this mode.
3. `_onPaymentSuccess` calls `BibleSessionRepository.payAndJoinBibleSession({sessionId, paymentId, orderId, signature})` ([bible_session_repository.dart:570-594](lib/features/shared/data/bible_session_repository.dart#L570-L594))
4. CF [payAndJoinBibleSession.ts](functions/src/bible/payAndJoinBibleSession.ts):
   - Session must be `status === 'live'` and have a non-empty `meetingLink`
   - Per-registration idempotency: if `bible_sessions/{sessionId}/registrations/{uid}.status === 'paid' && paymentId === paymentId`, return `meetingLink` without round-tripping Razorpay
   - Cross-session replay defence: `wallet_transactions.where('paymentId','==',paymentId).limit(1)` — if found, REJECT
   - `razorpay.payments.fetch(paymentId)` — `status` must be `'captured'` or `'authorized'` (then auto-capture); `currency==='INR'`; `amount === Math.round(session.price * 100)`
   - Commission split: reads `app_config/settings.bibleCommissionPercent` (default 20); `priestEarning = floor(price * (1 - pct/100))`, platform absorbs rounding
   - Batched writes:
     - Either `update` an existing reg → `status:'paid'`, `paymentId`, `paidAt`, `amountPaid`, `paidViaUpdate:true`
     - OR `set` a new reg with `status:'paid'`, `paidOnCreate:true` (Admin SDK bypasses the client rule that blocks first-write paid status)
     - `wallet_transactions` user row: `{userId, type:'bible_session', paymentId, sessionId, amountPaid, description, createdAt}`
     - `priests/{priestId}.walletBalance += priestEarning`, `totalEarnings += priestEarning`
     - `wallet_transactions` priest row: `{userId:priestId, type:'bible_session_earning', sessionId, paymentId, coins:priestEarning, description}`
     - Platform commission row: `{userId:'__platform__', type:'bible_session_commission', sessionId, paymentId, coins:platformCommission}`
     - Two `notifications` rows (user "You're in!" + priest "Payment Received")
   - Dismisses prior `bible_session_live` notification docs for this user/session
   - Two pushes via `sendPushNotification`
   - Returns `{meetingLink, alreadyProcessed}`

**After-success Firestore writes:** **server-side only.** The page's success handler launches the meeting URL and refreshes registration state via `_loadRegistration()`.

### 3.4 All payment-related Cloud Functions

All CFs are **callable v2** (`onCall` from `firebase-functions/v2/https`) and pinned to region `asia-south1` ([functions/src/config/constants.ts:1](functions/src/config/constants.ts#L1)).

| Function | File | Trigger | Inputs | What it writes |
|---|---|---|---|---|
| `createCoinOrder` | [functions/src/payments/createCoinOrder.ts](functions/src/payments/createCoinOrder.ts) | onCall | `{packId}` | Calls Razorpay Orders API. **No Firestore writes.** Returns `{orderId, amount, currency, keyId, coins, priceRupees}`. |
| `verifyCoinPurchase` | [functions/src/payments/verifyCoinPurchase.ts](functions/src/payments/verifyCoinPurchase.ts) | onCall | `{razorpayPaymentId, razorpayOrderId, razorpaySignature, packId}` | HMAC check + `orders.fetch`. Writes `users/{uid}.coinBalance += coins`, `wallet_transactions/*` (type `purchase`), `notifications/*`. Returns `{newBalance, alreadyProcessed}`. |
| `createActivationOrder` | [functions/src/payments/createActivationOrder.ts](functions/src/payments/createActivationOrder.ts) | onCall | `{}` | Razorpay Orders API. **No Firestore writes.** Returns `{orderId, amount, currency, keyId, priceRupees}`. |
| `verifyActivationFee` | [functions/src/payments/verifyActivationFee.ts](functions/src/payments/verifyActivationFee.ts) | onCall | `{razorpayPaymentId, razorpayOrderId, razorpaySignature}` | HMAC check + `orders.fetch`. Writes `priests/{uid}.isActivated=true + activatedAt + activationPaymentId`, `users/{uid}.isActivated=true`, `wallet_transactions/*` (type `activation_fee`), `notifications/*`. Returns `{success, alreadyActivated}`. |
| `verifyBibleSessionPayment` | [functions/src/payments/verifyBibleSessionPayment.ts](functions/src/payments/verifyBibleSessionPayment.ts) | onCall | `{sessionId, paymentId, amount}` | Direct-amount via `payments.fetch`. Capture-if-authorized. Writes `bible_sessions/{sid}/registrations/{uid}.status='paid'`, 3 `wallet_transactions` rows (user, priest, platform), 2 `notifications` rows, `priests/{pid}.walletBalance/totalEarnings`. **Still exported but not called by the live Bible flow.** Returns `{alreadyProcessed}`. |
| `payAndJoinBibleSession` | [functions/src/bible/payAndJoinBibleSession.ts](functions/src/bible/payAndJoinBibleSession.ts) | onCall | `{sessionId, paymentId, orderId?, signature?}` | Same set of writes as `verifyBibleSessionPayment` plus supports first-write paid creation (`paidOnCreate:true`) for non-registered users. Returns `{meetingLink, alreadyProcessed}`. |

**Razorpay webhook / capture / verify logic that lives outside the CFs above:** none. There is no inbound webhook endpoint registered in `functions/`. All verification is initiated by the client after a successful Razorpay callback.

**Stub files removed but referenced in git status:** [AUDIT_REPORT.md](AUDIT_REPORT.md) and the git pre-modification diff show these CFs were once present but are now deleted:
- `functions/src/admin/approveRejectMatrimony.ts` (stub, never deployed)
- `functions/src/admin/updateAppConfig.ts` (stub)
- `functions/src/notifications/sendNotification.ts` (stub)
- `functions/src/payments/verifyMatrimonyPayment.ts` (stub — Matrimony feature isn't shipping)
- `functions/src/priest/activatePriestAccount.ts` (orphan — superseded by `verifyActivationFee`)

None of these are deployed; none affect the migration.

### 3.5 Data models for transactions / wallet / coin packs

| Concept | File | Key fields |
|---|---|---|
| `CoinPackModel` (client) | [lib/features/admin/settings/data/coin_pack_model.dart](lib/features/admin/settings/data/coin_pack_model.dart) | `id, coins, price, label, order, isPopular, isActive`. Derived: `pricePerCoin, oldPrice, discountPercent` |
| `CoinOrder` DTO (response from `createCoinOrder`) | [lib/features/user/wallet/data/wallet_repository.dart:135-147](lib/features/user/wallet/data/wallet_repository.dart#L135-L147) | `orderId, amountPaise, coins, priceRupees` |
| `ActivationOrder` DTO | [lib/features/priest/activation/data/activation_repository.dart:22-32](lib/features/priest/activation/data/activation_repository.dart#L22-L32) | `orderId, amountPaise, priceRupees` |
| `WalletTransaction` (priest-side row) | [lib/features/priest/wallet/data/wallet_models.dart:12-87](lib/features/priest/wallet/data/wallet_models.dart#L12-L87) | `id, type, coins (signed), description, sessionId, createdAt` — recognised types: `session_charge, bible_session_earning, activation_fee, withdrawal, refund` |
| `BankDetails` | [lib/features/priest/wallet/data/wallet_models.dart:89-153](lib/features/priest/wallet/data/wallet_models.dart#L89-L153) | `accountHolderName, accountNumber, ifscCode, bankName, branchName, accountType, upiId`. Persisted on `priests/{uid}` with field names `bankAccountName/bankAccountNumber/bankIfscCode/bankName/bankBranchName/bankAccountType/upiId` |
| Firestore — pack doc | `app_config/coin_packs/packs/{packId}` | as above; doc id pattern `pack_<coins>` |
| Firestore — app config | `app_config/settings` | as listed in §2 |
| Firestore — wallet_transactions row | (no Dart model — server-written, reader-tolerant) | `userId, type, coins?/amountPaid?, paymentId?, orderId?, packId?, sessionId?, withdrawalId?, description?, createdAt` |
| Firestore — withdrawals row | `withdrawals/{clientRequestId}` ([requestWithdrawal.ts:109](functions/src/priest/requestWithdrawal.ts#L109)) | `priestId, amount, status('pending'|'paid'|'blocked'), clientRequestId, bankAccountName, bankAccountNumber, bankIfscCode, bankName, upiId, createdAt` |
| Firestore — bible registration | `bible_sessions/{sid}/registrations/{uid}` | `status('registered'|'paid'|'cancelled'), paymentId, paidAt, amountPaid, paidOnCreate?, paidViaUpdate?, userName, userPhotoUrl, registeredAt` |

---

## 4. WHAT MUST NOT BREAK

### 4.1 Priest WITHDRAWAL / payout system — KEEP UNTOUCHED

**Important reality check:** there is **no Razorpay Payouts / RazorpayX integration** in this codebase. The references to Razorpay X in code comments are aspirational only.

What actually exists today:

- CF [functions/src/priest/requestWithdrawal.ts](functions/src/priest/requestWithdrawal.ts):
  - Validates priest is `approved + isActivated`, has bank details, balance ≥ amount, amount ≥ `app_config/settings.minWithdrawalAmount`
  - Inside a Firestore `runTransaction`: idempotency check on `withdrawals/{clientRequestId}`, debits `priests/{uid}.walletBalance` by `amount`, bumps `totalWithdrawn`, writes the withdrawal doc in `status: 'pending'`, writes a ledger row `{type:'withdrawal', coins:-amount}`, writes a notification
  - **The actual bank transfer happens off-platform.** The admin payout dashboard flips `withdrawals/{id}.status` to `paid` after sending NEFT/IMPS manually.
- UI: [lib/features/priest/wallet/pages/priest_wallet_page.dart](lib/features/priest/wallet/pages/priest_wallet_page.dart) + [lib/features/priest/wallet/pages/bank_details_page.dart](lib/features/priest/wallet/pages/bank_details_page.dart)
- Repo: [lib/features/priest/wallet/data/priest_wallet_repository.dart](lib/features/priest/wallet/data/priest_wallet_repository.dart) + [lib/features/priest/wallet/data/wallet_models.dart](lib/features/priest/wallet/data/wallet_models.dart)
- IFSC autofill: [lib/core/services/ifsc_lookup_service.dart](lib/core/services/ifsc_lookup_service.dart) — uses Razorpay's free public `https://ifsc.razorpay.com/<IFSC>` directory. **Not authenticated, not billable, not part of payments.** Safe to keep. (If desired you can later swap to RBI's directory or another vendor, but no need for this migration.)

**This entire stack is independent of the Razorpay Payments SDK** and survives the migration unchanged. The `razorpay_flutter` package on the client is for inbound payments only; removing it does NOT affect withdrawals.

### 4.2 Coin economy that stays unchanged

Per-minute deduction, commission split, priest credit, partial-minute rollup, watchdog settlement — all of this is **decoupled from Razorpay** and must survive untouched:

| Component | File |
|---|---|
| User-side billing tick (one call per minute) | [functions/src/sessions/billingTick.ts](functions/src/sessions/billingTick.ts) |
| Session settlement + minimum-1-minute + partial-minute rollup | [functions/src/sessions/endSession.ts](functions/src/sessions/endSession.ts) |
| Stuck-session reaper (5-minute cron) | [functions/src/sessions/sessionWatchdog.ts](functions/src/sessions/sessionWatchdog.ts) |
| Pending-request expiry | [functions/src/sessions/expireSessionRequest.ts](functions/src/sessions/expireSessionRequest.ts) |
| Session creation gate (locks rate + commission per session) | [functions/src/sessions/createSessionRequest.ts](functions/src/sessions/createSessionRequest.ts) |
| User-side cubits driving the ticker | [lib/features/shared/bloc/chat_session_cubit.dart](lib/features/shared/bloc/chat_session_cubit.dart), [lib/features/shared/bloc/voice_call_cubit.dart](lib/features/shared/bloc/voice_call_cubit.dart) |
| Bible session priest credit (commission split logic only — currency-in stays IAP) | [functions/src/bible/payAndJoinBibleSession.ts:214-242](functions/src/bible/payAndJoinBibleSession.ts#L214-L242) |
| Wallet read APIs | [lib/features/user/wallet/data/wallet_repository.dart](lib/features/user/wallet/data/wallet_repository.dart), [lib/features/priest/wallet/data/priest_wallet_repository.dart](lib/features/priest/wallet/data/priest_wallet_repository.dart) |
| `wallet_transactions` ledger writes (types `session_charge, bible_session_earning, bible_session_commission, withdrawal`) | as above |

See [BILLING_ANALYSIS.md](BILLING_ANALYSIS.md) for a deep dive on this economy — that document confirms billing logic is fully Razorpay-independent.

### 4.3 Other Razorpay usage beyond the three purchase flows

- **IFSC directory lookup** ([lib/core/services/ifsc_lookup_service.dart](lib/core/services/ifsc_lookup_service.dart)) — free public API, no key. Keep as-is.
- **Impeller-disabled meta-data in Android manifest** ([AndroidManifest.xml:183-192](android/app/src/main/AndroidManifest.xml#L183-L192)) — kept for now because Razorpay's WebView triggered the workaround. After removing Razorpay you can safely re-enable Impeller, but it's safe to leave the meta-data either way.
- **Legal/help/refund copy** in [legal/](legal/) and [public/](public/) — references Razorpay by name; needs editorial updates.

### 4.4 Money IN (TO REPLACE) vs Money OUT / economy (KEEP UNTOUCHED)

| Direction | Surface | Today | Migration action |
|---|---|---|---|
| Money IN | Coin pack purchase (user) | Razorpay → CF | Replace with Play Billing (Android) + StoreKit IAP (iOS); rewrite `createCoinOrder` + `verifyCoinPurchase` |
| Money IN | Priest activation fee (priest) | Razorpay → CF | Same (Play/IAP); rewrite `createActivationOrder` + `verifyActivationFee` |
| Money IN | Bible session pay-to-join (user) | Razorpay → CF | Same (Play/IAP); rewrite `payAndJoinBibleSession` and the legacy `verifyBibleSessionPayment` |
| Money OUT / internal | Per-minute coin deduction | `billingTick` | NO CHANGE |
| Money OUT / internal | Session end / minimum charge / partial-minute rollup | `endSession` | NO CHANGE |
| Money OUT / internal | Watchdog settlement | `sessionWatchdog` | NO CHANGE |
| Money OUT / internal | Priest commission credit per minute | `billingTick`, `endSession` | NO CHANGE |
| Money OUT / internal | Bible session priest credit + platform commission | inside `payAndJoinBibleSession` — keep the SPLIT logic, just feed it from the new IAP-verify | Refactor target: extract the commission-split + ledger writes into a helper and call it from the new IAP-verify CFs |
| Money OUT / external | Priest withdrawal (bank payout) | Admin-processed off-platform after `requestWithdrawal` writes pending doc | NO CHANGE |
| Money OUT (read) | Wallet history, balance display | `wallet_transactions`, `users/{uid}.coinBalance`, `priests/{uid}.walletBalance` | NO CHANGE — ledger row shape stays the same; only `type` values for the IN side may grow (`purchase_play`, `purchase_iap` or stay as `purchase` with extra fields) |

---

## 5. CLIENT ↔ CLOUD FUNCTION CONTRACT

### Callable signatures (in current use)

| CF name | Region | Inputs | Outputs |
|---|---|---|---|
| `createCoinOrder` | `asia-south1` | `{packId: string}` | `{orderId, amount, currency, keyId, coins, priceRupees}` |
| `verifyCoinPurchase` | `asia-south1` | `{razorpayPaymentId, razorpayOrderId, razorpaySignature, packId}` | `{newBalance, alreadyProcessed}` |
| `createActivationOrder` | `asia-south1` | `{}` | `{orderId, amount, currency, keyId, priceRupees}` |
| `verifyActivationFee` | `asia-south1` | `{razorpayPaymentId, razorpayOrderId, razorpaySignature}` | `{success, alreadyActivated}` |
| `verifyBibleSessionPayment` (legacy) | `asia-south1` | `{sessionId, paymentId, amount}` | `{alreadyProcessed}` |
| `payAndJoinBibleSession` | `asia-south1` | `{sessionId, paymentId, orderId?, signature?}` | `{meetingLink, alreadyProcessed}` |

Plus the non-payment callables involved (kept):
- `requestWithdrawal` — `{amount:int, clientRequestId:string}` → `{withdrawalId, newBalance, amount, deduplicated}`
- `billingTick` — `{sessionId}` → `{remainingBalance, totalCharged, durationMinutes, shouldEnd}`
- `endSession`, `createSessionRequest`, `expireSessionRequest`, `sessionWatchdog`, `generateAgoraToken`, plus the Bible session lifecycle CFs

### Invocation style on the client

Always `FirebaseFunctions.instanceFor(region: 'asia-south1').httpsCallable('<name>').call({...})` — wrapped per-callable in a repository class with a `.timeout(Duration(seconds: 10..30))`. Examples:
- [wallet_repository.dart:99-111](lib/features/user/wallet/data/wallet_repository.dart#L99-L111), [wallet_repository.dart:117-132](lib/features/user/wallet/data/wallet_repository.dart#L117-L132)
- [activation_repository.dart:50-77](lib/features/priest/activation/data/activation_repository.dart#L50-L77)
- [bible_session_repository.dart:520-594](lib/features/shared/data/bible_session_repository.dart#L520-L594)

### Error handling pattern

- CFs throw `HttpsError(code, message, details?)` with stable `code` strings: `unauthenticated, invalid-argument, failed-precondition, permission-denied, not-found, internal`. `details.reason` token used selectively (notably in `requestWithdrawal` — `invalid_amount, below_minimum, account_inactive, no_bank_details, insufficient_balance, request_id_conflict`).
- Client side catches `FirebaseFunctionsException` and string-switches on `code` (e.g. [activation_cubit.dart:187-210](lib/features/priest/activation/bloc/activation_cubit.dart#L187-L210)).
- Verify-path failures use a separate `afterCapture: true` flag so the UI hides retry buttons that would re-charge ([activation_paywall_page.dart:265-326](lib/features/priest/activation/pages/activation_paywall_page.dart#L265-L326), [wallet_page.dart:46-54](lib/features/user/wallet/pages/wallet_page.dart#L46-L54)).
- Token freshness: every payment-trigger client call does `user.getIdToken(true)` first — non-negotiable workaround for Samsung's aggressive background freeze.

### Region & deployment

- Region: `asia-south1` (Mumbai) — set by `{region: REGION}` in every `onCall(...)` decorator
- Node runtime: `20` ([functions/package.json:13-14](functions/package.json#L13-L14))
- Deploy: `firebase deploy --only functions` with predeploy `npm --prefix functions run build` (i.e. `tsc`), per [firebase.json:34-49](firebase.json#L34-L49)
- All payment CFs are **callable v2** (`firebase-functions/v2/https.onCall`), not v1, not HTTP, not Firestore-triggered.

---

## 6. PLATFORM CONFIG

### Android ([android/app/build.gradle.kts](android/app/build.gradle.kts), [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml))

- `applicationId` / namespace: **`com.gospelvox.gospel_vox`** ([build.gradle.kts:39](android/app/build.gradle.kts#L39), [build.gradle.kts:58](android/app/build.gradle.kts#L58))
- `versionCode` / `versionName`: inherited from `pubspec.yaml`'s `1.0.0+8` via Flutter's `flutter.versionCode` / `flutter.versionName` ([build.gradle.kts:61-62](android/app/build.gradle.kts#L61-L62))
- `minSdk` / `targetSdk` / `compileSdk`: inherited from Flutter SDK defaults via `flutter.minSdkVersion / flutter.targetSdkVersion / flutter.compileSdkVersion` ([build.gradle.kts:40-41](android/app/build.gradle.kts#L40-L41), [build.gradle.kts:59-60](android/app/build.gradle.kts#L59-L60)). **The launcher icons config separately pins `min_sdk_android: 21`** ([pubspec.yaml:141](pubspec.yaml#L141)) but that only affects icon generation, not runtime.
- `compileOptions`: Java 17, `isCoreLibraryDesugaringEnabled = true` (required by `flutter_local_notifications 21+`); `desugar_jdk_libs:2.1.4` in deps
- Signing: optional release keystore via `android/key.properties` (gitignored); falls back to debug key when absent
- Plugins: `com.android.application`, `com.google.gms.google-services`, `com.google.firebase.crashlytics`, `kotlin-android`, `dev.flutter.flutter-gradle-plugin`

**Current permissions ([AndroidManifest.xml:28-106](android/app/src/main/AndroidManifest.xml#L28-L106)):**
- `INTERNET`, `ACCESS_NETWORK_STATE`
- `CAMERA`, `READ_EXTERNAL_STORAGE` (maxSdk 32), `READ_MEDIA_IMAGES` (removed via `tools:node="remove"` — falls back to system Photo Picker)
- `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH` (maxSdk 30), `BLUETOOTH_CONNECT`
- `POST_NOTIFICATIONS`
- `WAKE_LOCK`, `USE_FULL_SCREEN_INTENT`, `VIBRATE`
- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`
- `FOREGROUND_SERVICE_MEDIA_PROJECTION` — explicitly REMOVED via `tools:node="remove"` (Agora injects it; we don't use screen sharing)
- Services: `CallForegroundService` (microphone foreground service for live calls)
- Meta-data: FCM default channel/icon/color, `EnableImpeller=false` (Razorpay rendering workaround), `flutterEmbedding=2`
- Activity: `MainActivity` with deep-link `intent-filter` for `gospelvox://priest/<uid>` (custom scheme) + `https://gospelvox.app/priest/...` (App Links, `autoVerify=true`)

**Play Billing library / `com.android.vending.BILLING` permission:** **NOT PRESENT.** No `BILLING` permission. No `in_app_purchase` Flutter plugin. No `com.android.billingclient` Gradle dependency. This is the expected starting state.

### iOS ([ios/Runner/Info.plist](ios/Runner/Info.plist), [ios/Runner.xcodeproj/project.pbxproj](ios/Runner.xcodeproj/project.pbxproj), [ios/Runner/Runner.entitlements](ios/Runner/Runner.entitlements))

- Bundle identifier: **`com.gospelvox.gospelVox`** (note the capital `V` and dropped underscore — different from the Android applicationId) ([project.pbxproj:371](ios/Runner.xcodeproj/project.pbxproj#L371), [project.pbxproj:550](ios/Runner.xcodeproj/project.pbxproj#L550), [project.pbxproj:572](ios/Runner.xcodeproj/project.pbxproj#L572))
- Display name: `GospelVox`; Bundle name: `gospel_vox`
- `CFBundleVersion` / `CFBundleShortVersionString`: bound to Flutter `$(FLUTTER_BUILD_NUMBER)` / `$(FLUTTER_BUILD_NAME)` (so `1.0.0+8`)
- `LSRequiresIPhoneOS=true`; orientations support portrait + landscape (portrait-only on iPhone for some flows)
- Deep link: `CFBundleURLSchemes` includes `gospelvox` (custom scheme); Universal Links not configured yet (no `associated-domains` entitlement)
- `UIBackgroundModes`: `audio`, `voip`, `remote-notification` — for live Agora calls + silent FCM
- Privacy strings present: `NSMicrophoneUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`
- Entitlements: file exists at [ios/Runner/Runner.entitlements](ios/Runner/Runner.entitlements) (contents not enumerated here; typically just APS environment for FCM)
- No Podfile committed to source (`ios/Podfile` is in `.gitignore` typically — but here the search returned no Podfile at all, suggesting it's regenerated by `pod install` from Flutter's plugin manifest at build time)

**StoreKit / IAP configured yet:** **NO.** No `in_app_purchase` Flutter plugin, no `StoreKit.framework` references in `pbxproj`, no `In-App Purchase` capability listed. No `Products.storekit` config file. This is the expected starting state.

---

## 7. RISKS / NOTES FOR THE MIGRATION

### Things that would make removing Razorpay risky

1. **The test Razorpay key is hard-coded** ([payment_config.dart:51](lib/core/config/payment_config.dart#L51)). When you delete `razorpay_flutter`, also delete this whole file — but search for `PaymentConfig.razorpayKeyId`, `companyName`, `companyDescription`, `toPaise`, `checkoutThemeHex` callers first; they're imported by `razorpay_service.dart` and the wallet UI uses `checkoutColor`/`checkoutThemeHex` for theming the failure sheet.
2. **`Razorpay`'s WebView was the reason Impeller is disabled** in the Android manifest. After removing Razorpay you can re-enable Impeller — but test thoroughly first (Bible session detail page uses a lot of cached network images that have separate Impeller compatibility history).
3. **Three different UI files own their own `RazorpayService` lifecycle.** All three must be removed in lockstep, otherwise a stranded import of `package:razorpay_flutter/razorpay_flutter.dart` keeps the package in the dep graph:
   - [lib/features/user/wallet/pages/wallet_page.dart](lib/features/user/wallet/pages/wallet_page.dart) (line 8 import)
   - [lib/features/priest/activation/pages/activation_paywall_page.dart](lib/features/priest/activation/pages/activation_paywall_page.dart) (line 21 import)
   - [lib/features/user/bible/pages/bible_session_detail_page.dart](lib/features/user/bible/pages/bible_session_detail_page.dart) (line 27 import)
   - [lib/features/shared/widgets/recharge_sheet.dart](lib/features/shared/widgets/recharge_sheet.dart) (line 28 import)
4. **`PaymentFailureSheet`** ([lib/features/user/wallet/widgets/payment_failure_sheet.dart](lib/features/user/wallet/widgets/payment_failure_sheet.dart)) is shared by both the wallet and the activation paywall. It accepts a `paymentId` and copy is generic enough to work for either store, but verify the copy still reads correctly (it says "Razorpay" nowhere in the current code I saw, but the page that invokes it does).
5. **The CFs in `functions/src/payments/` and `functions/src/bible/payAndJoinBibleSession.ts` will be heavily rewritten.** Don't just delete — the post-credit logic (ledger row, notification, push, commission split) is reusable and aligned across all three. Plan to extract those into shared helpers BEFORE the rewrite so all three new IAP-verify CFs share the same persistence layer.
6. **`razorpay: ^2.9.6` in `functions/package.json`** must be removed AND `functions/.env`'s `RAZORPAY_KEY_ID` / `RAZORPAY_KEY_SECRET` entries can be deleted. Watch out for any `.env` template / CI secret rotation.
7. **Coin packs are admin-edited Firestore docs, not a closed product catalogue.** Google Play and App Store require products to be pre-declared in the consoles. You'll need a deterministic mapping between `packs/{packId}` and the store SKUs. Three approaches, pick one before coding:
   - Keep `packs/{packId}` as the source of truth and store `androidSku` / `iosSku` fields on each pack doc; the admin UI gains two new text fields
   - Move to a fixed code-side SKU table per platform; the admin Firestore UI becomes read-only / hidden in production
   - Hybrid: code-side SKU constants for v1, sync to Firestore on app start for display only
8. **The "welcome offer" is a synthetic pack with `packId='welcome_offer'`** ([createCoinOrder.ts:48-85](functions/src/payments/createCoinOrder.ts#L48-L85)). It needs its own store SKU and an `INTRODUCTORY` flag (Play) or `Introductory Offer` (Apple). Or fold it into a single SKU with a server-side eligibility check (current pattern) but the price is hard-coded into the store, not Firestore — so changing the price means a store update, not a Firestore edit.
9. **Currency lock:** all CFs check `currency === 'INR'` (e.g. [verifyBibleSessionPayment.ts:179-184](functions/src/payments/verifyBibleSessionPayment.ts#L179-L184)). Store-side IAP runs in the user's local currency; the server cannot enforce a single currency. The ledger row's `amountPaid` would need to record the local currency code + the user's locale-priced amount, and the coin/credit count would be looked up by SKU (not by paid amount). This is a substantial schema change worth planning explicitly.
10. **Per-user distribution is 80% India** (per saved memory `project_user_distribution.md`). India's IAP gating is enforced by Google for digital goods; Razorpay was the path of least resistance precisely because the user base is India-heavy. Confirm the store fee economics still work at 70/30 (Apple) and 85/15 + commission (Play after $1M revenue) on coin prices like ₹29, ₹49, ₹99.
11. **Priest activation fee is sold to PRIESTS, not consumers.** Both Apple and Google have carve-outs for B2B / "real-world service" payments, but the line between "consumer paying ₹500 to unlock app features" and "B2B SaaS fee" is policy-fuzzy. Risk: store rejection if it's classified as a digital-content unlock vs. service-provider activation. Worth confirming with both consoles' policy teams before shipping.
12. **Bible session pay-to-join may qualify as a "person-to-person service"** (Google's wording) when the priest hosts a live Meet — Google explicitly allows this off-IAP. Apple's stance is stricter. Different products on each platform may end up being required.

### Places where the client writes financial data directly

**None on the inbound side.** Audit notes ([AUDIT_REPORT.md](AUDIT_REPORT.md)) and a fresh read of the code confirm:
- `users/{uid}.coinBalance` is server-only (CF `verifyCoinPurchase` increments; `billingTick`/`endSession` decrement). Firestore rules block client writes.
- `priests/{uid}.walletBalance` / `totalEarnings` is server-only.
- `wallet_transactions` is server-only (all rows written from CFs with the Admin SDK).
- Bible registrations: the client can `set` with `status:'registered'` (free registration) or `update` to flip its own row to `cancelled`. The `'paid'` status can ONLY be reached via the Admin SDK inside `payAndJoinBibleSession` / `verifyBibleSessionPayment` (Firestore rules deny client `status:'paid'` per the audit notes).
- Priest activation: `priests/{uid}.isActivated` flipped only by `verifyActivationFee`.

**On the outbound side (withdrawals):** withdrawals are created **only** through the `requestWithdrawal` CF inside a Firestore transaction. The bank-details fields ON `priests/{uid}` (`bankAccountName`, `bankAccountNumber`, `bankIfscCode`, `bankName`, `bankBranchName`, `bankAccountType`, `upiId`) ARE written by the client from the bank-details page (necessary for the priest to enter their own bank details). The withdrawal CF re-reads them and stamps them into the `withdrawals/{id}` snapshot at debit time so a later edit on the priest doc doesn't affect a pending payout's snapshot.

### Dependency conflicts that adding `in_app_purchase` might cause

- `in_app_purchase: ^3.x` officially supports Flutter `>=3.16` — comfortably within our `>=3.38.4` floor. No conflict.
- It depends transitively on `in_app_purchase_android` and `in_app_purchase_storekit` (both Flutter team-maintained). No known clash with any current dep.
- On Android it adds the `com.android.billingclient:billing` Gradle dep automatically; minSdk must be `21+` (we're already at Flutter's default minSdk via `flutter.minSdkVersion` and the launcher icons config explicitly states `min_sdk_android: 21`, so we're aligned).
- On iOS it requires `In-App Purchase` capability + linking `StoreKit.framework` — both handled by the plugin's CocoaPods spec.
- Manifest: adds `<uses-permission android:name="com.android.vending.BILLING" />` automatically. Confirm this lands; today no BILLING permission is declared anywhere.
- The Android manifest's `EnableImpeller=false` workaround stays compatible — Play Billing has no UI rendering of its own (it's an out-of-process system dialog), so the rendering hack is purely Razorpay's problem.
- ProGuard / R8: the current Gradle config has no custom `proguard-rules.pro`; the Play Billing plugin ships its own consumer rules so nothing extra is needed.
- **No clash with `razorpay_flutter`** during a transitional period — `in_app_purchase` and `razorpay_flutter` can coexist on `compile` if a phased migration is desired (e.g. ship IAP for new builds while old install bases still receive Razorpay verify calls). However, App Store review will reject an app that ships both unless one is feature-flagged off for that platform — Apple's IAP-only rule is per-build, not per-locale.
- Risk: Firebase App Check (not currently configured in this repo per my read) will need an Android `PlayIntegrity` provider rather than `SafetyNet` once you start consuming Play Billing tokens server-side, but this only matters if App Check gets enabled.

### Operational risks specific to this codebase

- **`functions/lib/**/*.js` is checked into git** (per current `git status` showing modified `.js`/`.js.map` files). That's the compiled TypeScript output. After deleting `razorpay`, both `.ts` AND `.js` paths need to be removed; `firebase deploy` rebuilds `.js` from `.ts` via the `predeploy` hook, but if the stale `.js` lingers in git it looks like dead code in PR review.
- **Idempotency contract**: every payment CF dedupes on `wallet_transactions.where('paymentId', '==', razorpayPaymentId)`. The IAP equivalents will need to dedupe on `purchaseToken` (Play) / `originalTransactionId` (StoreKit). The schema change is small (add a `provider:'play'|'iap'` field, treat `paymentId` as a generic token) but the CFs all share this pattern so consistency matters.
- **Multiple notification copies refer to "₹" and the rupee literal** in CF code. If IAP introduces multi-currency, the notification body builders ([verifyCoinPurchase.ts:182-189](functions/src/payments/verifyCoinPurchase.ts#L182-L189), etc.) need to localise.
- **`recharge_sheet.dart` is the highest-traffic payment surface** because it's the in-call top-up. Pay particular UX attention here — it has the warm-cache fast-path optimisation and the user is mid-conversation. The IAP flow on Android can take 2–3 seconds to show the Google sheet even on warm cache; surface a localised loading state.
- **Refund policy / privacy / terms / help pages all mention Razorpay by name** (8 separate HTML/MD docs under [legal/](legal/) and [public/](public/)). Plan editorial pass + re-publish to Firebase Hosting as part of the migration; not a code change but a launch-blocking item.

---

**End of analysis.** Read-only — no source files modified. The data model, ledger semantics, billing economy, withdrawal pipeline, and Firebase wiring are all designed to survive a payment-provider swap; the surgery is concentrated in the three trigger pages + their cubits + their CFs.
