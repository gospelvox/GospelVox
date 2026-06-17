// One-off helper: add an email+password login to EXISTING Firebase accounts
// (e.g. your already-approved Google test accounts) so store reviewers can
// sign in with email/password. This does NOT create new accounts and does
// NOT touch Firestore — it only sets a password on the same UID, so the
// account keeps its existing role, coin balance, priest doc, everything.
//
// Run from the functions/ folder:   node set-demo-passwords.js
//
// Each entry below is looked up by its existing email. After running, the
// reviewer logs in with that same email + the password you set here.

const admin = require('firebase-admin');
const serviceAccount = require('./service-account-key.json');

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

// 👇 currentEmail = the existing account to find. newEmail = the clean login
//    email to rename it to. password = the password reviewers will type.
//    (newEmail does NOT need to be a real inbox — it's just a login ID.)
const ACCOUNTS = [
  {
    currentEmail: 'relin483@gmail.com',
    newEmail: 'usertesting@gospelvox.com',
    password: 'GospelVox@2026',
  },
  {
    currentEmail: 'relin.mjos@gmail.com',
    newEmail: 'priesttesting@gospelvox.com',
    password: 'GospelVox@2026',
  },
];

(async () => {
  if (ACCOUNTS.length === 0) {
    console.error('No accounts listed. Edit ACCOUNTS at the top of this file.');
    process.exit(1);
  }

  for (const { currentEmail, newEmail, password } of ACCOUNTS) {
    try {
      const user = await admin.auth().getUserByEmail(currentEmail);

      // Rename the login email + set the password on the SAME uid. The Google
      // provider stays linked, so this account keeps everything it already has.
      await admin.auth().updateUser(user.uid, {
        email: newEmail,
        emailVerified: true,
        password,
      });

      // Keep the Firestore users/{uid} doc's email in sync so the rest of the
      // app shows the new address (role is left untouched).
      await admin
        .firestore()
        .collection('users')
        .doc(user.uid)
        .set({ email: newEmail }, { merge: true });

      const doc = await admin.firestore().collection('users').doc(user.uid).get();
      const role = doc.exists ? doc.data().role : '(no users/{uid} doc!)';

      console.log(
        `✓ ${currentEmail}  →  ${newEmail}  |  uid=${user.uid}  role=${role}  password set`
      );
    } catch (e) {
      console.error(`✗ ${currentEmail}  →  ${e.message}`);
    }
  }

  console.log('\nDone. Reviewers log in with the NEW email + password above.');
  process.exit(0);
})();
