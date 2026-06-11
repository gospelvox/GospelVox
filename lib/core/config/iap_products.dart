// Single source of truth for every Play Console / App Store product
// ID the app knows about. Centralising these constants here means:
//   • A typo in a SKU surfaces as a compile error, not a silent
//     "not found in store" at runtime.
//   • The full catalogue is auditable in one file when launching new
//     packs in Play Console.
//   • The pack_<N> → coins_<N> mapping lives ONCE — previously it
//     was duplicated as a regex in wallet_cubit.dart and
//     recharge_sheet.dart, so a change to the SKU naming
//     convention required editing two unrelated files.
//
// What lives here is the *contract* — string IDs and their grouping
// sets. Anything that requires server state (price, coin grant,
// active/inactive flag) lives in Firestore `app_config/coin_packs`
// and is fetched at runtime via CoinPacksRepository.
//
// Adding a new coin pack is a two-step process:
//   1. Create the SKU in Play Console (matching the constant name).
//   2. Add the constant here AND add it to `allCoinPacks`.
// Skipping either step is the most common cause of a launched pack
// appearing greyed-out at runtime.

class IapProducts {
  IapProducts._();

  // ─── Coin packs (consumable) ──────────────────────────────────
  // SKUs configured in Play Console. The Firestore admin can mark
  // any of these active/inactive in `app_config/coin_packs/packs`,
  // but cannot introduce a new SKU without adding the constant
  // here and creating the matching Play Console product.

  static const coins100 = 'coins_100';
  static const coins220 = 'coins_220';
  static const coins600 = 'coins_600';
  static const coins1300 = 'coins_1300';
  static const coins2000 = 'coins_2000';
  static const coins3000 = 'coins_3000';
  static const coins5000 = 'coins_5000';
  static const coins10000 = 'coins_10000';

  static const Set<String> allCoinPacks = {
    coins100,
    coins220,
    coins600,
    coins1300,
    coins2000,
    coins3000,
    coins5000,
    coins10000,
  };

  // ─── Priest activation (non-consumable) ──────────────────────
  // Wired through ActivationCubit → IapService.buyNonConsumable
  // → verifyActivationPurchase CF (acknowledge mode on Play, so
  // the SKU stays "owned" forever and restorePurchases brings
  // activation back on a fresh install).

  static const priestActivation = 'priest_activation';

  // ─── Bible session entry (consumable, fixed ₹199) ────────────
  // Every Bible session uses the same single SKU regardless of
  // who the priest is or what topic they teach — collapsing the
  // tier model into a single product to keep the Play Console
  // catalogue and the commission-split arithmetic anchored to
  // one number. The Bible detail page's payment rail is wired
  // through verifyAndJoinBibleSession (live on the server,
  // client wiring is the in-progress Step 4 migration).

  static const bibleSession199 = 'bible_session_199';

  // Rupee price for the Bible session SKU. The single source of
  // truth client-side — the createBibleSession CF enforces the
  // same number, and the priest create form passes this constant
  // through to the repo (no priest-controlled price input).
  static const int bibleSessionPriceRupees = 199;

  // Union of every Play product the app might query — used by
  // IapService.queryProducts to warm the store cache in a single
  // round-trip when more product types come online.
  static const Set<String> allProductIds = {
    ...allCoinPacks,
    priestActivation,
    bibleSession199,
  };

  // ─── Helpers ──────────────────────────────────────────────────

  // Maps a Firestore pack doc id (`pack_<N>`) to its Play Console
  // product id (`coins_<N>`). Returns null when the input doesn't
  // follow the convention.
  //
  // Deliberately does NOT enforce membership against `allCoinPacks`
  // here — the IapService.queryProducts response (notFoundIDs) is
  // the runtime authority for whether a SKU is live in Play
  // Console. Failing-fast here would silently hide a freshly
  // launched pack whose constant slipped past a code review.
  static String? packIdToProductId(String packId) {
    final match = RegExp(r'^pack_(\d+)$').firstMatch(packId);
    if (match == null) return null;
    return 'coins_${match.group(1)}';
  }
}
