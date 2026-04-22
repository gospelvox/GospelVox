const admin = require('firebase-admin');
const serviceAccount = require('./service-account-key.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

async function seed() {
  console.log('Starting Firestore seed...\n');

  // ─────────────────────────────────────
  // 1. app_config/settings — platform rates, fees, limits
  // ─────────────────────────────────────
  await db.doc('app_config/settings').set({
    // Session rates (coins per minute)
    chatRatePerMinute: 10,
    voiceRatePerMinute: 15,

    // Platform commission on priest earnings
    commissionPercent: 20,

    // Priest one-time activation fee (INR)
    priestActivationFee: 500,

    // Bible session — platform commission on user payment
    bibleSessionCommissionPercent: 15,

    // Matrimony fees (INR)
    matrimonyListingFee: 1500,
    matrimonyUnlockFee: 299,
    matrimonyChatTierFee: 50,
    matrimonyChatTierMessages: 200,
    matrimonyFreeMessages: 50,
    matrimonyFreeMessageMaxChars: 5,

    // Wallet limits
    lowBalanceWarning: 50,
    minWithdrawal: 500,

    // Welcome offer for first-time users
    welcomeOfferCoins: 100,
    welcomeOfferPrice: 29,

    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  console.log('✅ app_config/settings — 16 fields created');

  // ─────────────────────────────────────
  // 2. app_config/coin_packs — 8 default packs
  // ─────────────────────────────────────
  const coinPacks = [
    { coins: 100, price: 99, label: 'Starter', order: 1, isPopular: false, isActive: true },
    { coins: 220, price: 199, label: 'Most Popular', order: 2, isPopular: true, isActive: true },
    { coins: 600, price: 499, label: 'Value', order: 3, isPopular: false, isActive: true },
    { coins: 1300, price: 999, label: 'Best Value', order: 4, isPopular: false, isActive: true },
    { coins: 2000, price: 1599, label: 'Premium', order: 5, isPopular: false, isActive: true },
    { coins: 3000, price: 2299, label: 'Pro', order: 6, isPopular: false, isActive: true },
    { coins: 5000, price: 3499, label: 'Elite', order: 7, isPopular: false, isActive: true },
    { coins: 10000, price: 6999, label: 'Ultimate', order: 8, isPopular: false, isActive: true },
  ];

  for (const pack of coinPacks) {
    await db.collection('app_config').doc('coin_packs')
      .collection('packs').doc(`pack_${pack.coins}`).set({
        ...pack,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
  }
  console.log('✅ app_config/coin_packs — 8 packs created');

  // ─────────────────────────────────────
  // 3. Create all collections with placeholder docs
  // ─────────────────────────────────────
  const collections = [
    'priests',
    'sessions',
    'bible_sessions',
    'matrimony_profiles',
    'wallet_transactions',
    'withdrawals',
    'reports',
    'notifications',
  ];

  for (const name of collections) {
    await db.collection(name).doc('_placeholder').set({
      _note: 'Placeholder doc — safe to delete after first real document exists',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log(`✅ ${name} collection created`);
  }

  // ─────────────────────────────────────
  console.log('\n🎉 Firestore seed complete!');
  console.log('─────────────────────────────');
  console.log('app_config/settings: 16 fields');
  console.log('app_config/coin_packs: 8 packs');
  console.log('Collections created: ' + collections.length);
  console.log('Total collections: ' + (collections.length + 2) + ' (including users + app_config)');
  console.log('\n⚠️  DELETE scripts/service-account-key.json NOW');
  process.exit(0);
}

seed().catch((err) => {
  console.error('❌ Seed failed:', err);
  process.exit(1);
});
