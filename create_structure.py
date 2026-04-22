import os

BASE = "lib"

files = [
    # core
    ("core/constants/app_strings.dart",          "App-wide string constants for Gospel Vox",                       "AppStrings"),
    ("core/theme/app_colors.dart",               "Color palette for the Gospel Vox design system",                  "AppColors"),
    ("core/theme/app_spacing.dart",              "Spacing constants based on a 4-pt grid",                         "AppSpacing"),
    ("core/theme/app_text_styles.dart",          "Typography styles for the Gospel Vox design system",              "AppTextStyles"),
    ("core/theme/app_theme.dart",                "Material ThemeData configuration for Gospel Vox",                 "AppTheme"),
    ("core/utils/app_utils.dart",                "General utility and helper functions",                            "AppUtils"),
    ("core/widgets/app_loading_widget.dart",     "Shared loading indicator widget",                                 "AppLoadingWidget"),
    ("core/services/app_service.dart",           "Base service interface and shared service utilities",             "AppService"),
    # auth
    ("features/auth/bloc/auth_bloc.dart",        "BLoC for authentication state management",                       "AuthBloc"),
    ("features/auth/pages/login_page.dart",      "Login page for Gospel Vox",                                      "LoginPage"),
    ("features/auth/widgets/auth_widgets.dart",  "Shared widgets for the auth feature",                            "AuthWidgets"),
    # user/home
    ("features/user/home/bloc/home_bloc.dart",        "BLoC for user home screen state",                           "HomeBloc"),
    ("features/user/home/pages/home_page.dart",       "Home screen for the user role",                             "HomePage"),
    ("features/user/home/widgets/home_widgets.dart",  "Widgets for the user home feature",                         "HomeWidgets"),
    # user/session
    ("features/user/session/bloc/session_bloc.dart",        "BLoC for user session state management",              "SessionBloc"),
    ("features/user/session/pages/session_page.dart",       "Session booking and consultation screen",             "SessionPage"),
    ("features/user/session/widgets/session_widgets.dart",  "Widgets for the user session feature",                "SessionWidgets"),
    # user/wallet
    ("features/user/wallet/bloc/wallet_bloc.dart",        "BLoC for user wallet state management",                 "WalletBloc"),
    ("features/user/wallet/pages/wallet_page.dart",       "Wallet screen for recharging and transactions",         "WalletPage"),
    ("features/user/wallet/widgets/wallet_widgets.dart",  "Widgets for the user wallet feature",                   "WalletWidgets"),
    # user/bible_sessions
    ("features/user/bible_sessions/bloc/bible_sessions_bloc.dart",        "BLoC for bible sessions state management",  "BibleSessionsBloc"),
    ("features/user/bible_sessions/pages/bible_sessions_page.dart",       "Bible study and group session screen",      "BibleSessionsPage"),
    ("features/user/bible_sessions/widgets/bible_sessions_widgets.dart",  "Widgets for the bible sessions feature",    "BibleSessionsWidgets"),
    # user/profile
    ("features/user/profile/bloc/profile_bloc.dart",        "BLoC for user profile state management",              "ProfileBloc"),
    ("features/user/profile/pages/profile_page.dart",       "User profile view and edit screen",                   "ProfilePage"),
    ("features/user/profile/widgets/profile_widgets.dart",  "Widgets for the user profile feature",                "ProfileWidgets"),
    # user/matrimony
    ("features/user/matrimony/bloc/matrimony_bloc.dart",        "BLoC for matrimony feature state management",     "MatrimonyBloc"),
    ("features/user/matrimony/pages/matrimony_page.dart",       "Matrimony browse and match screen",               "MatrimonyPage"),
    ("features/user/matrimony/widgets/matrimony_widgets.dart",  "Widgets for the matrimony feature",               "MatrimonyWidgets"),
    # priest/dashboard
    ("features/priest/dashboard/bloc/priest_dashboard_bloc.dart",        "BLoC for priest dashboard state",              "PriestDashboardBloc"),
    ("features/priest/dashboard/pages/priest_dashboard_page.dart",       "Main dashboard screen for the priest role",    "PriestDashboardPage"),
    ("features/priest/dashboard/widgets/priest_dashboard_widgets.dart",  "Widgets for the priest dashboard feature",     "PriestDashboardWidgets"),
    # priest/session
    ("features/priest/session/bloc/priest_session_bloc.dart",        "BLoC for priest session management",              "PriestSessionBloc"),
    ("features/priest/session/pages/priest_session_page.dart",       "Active consultation session screen for priests",  "PriestSessionPage"),
    ("features/priest/session/widgets/priest_session_widgets.dart",  "Widgets for the priest session feature",          "PriestSessionWidgets"),
    # priest/wallet
    ("features/priest/wallet/bloc/priest_wallet_bloc.dart",        "BLoC for priest earnings and wallet state",  "PriestWalletBloc"),
    ("features/priest/wallet/pages/priest_wallet_page.dart",       "Wallet and earnings screen for priests",     "PriestWalletPage"),
    ("features/priest/wallet/widgets/priest_wallet_widgets.dart",  "Widgets for the priest wallet feature",      "PriestWalletWidgets"),
    # priest/bible_sessions
    ("features/priest/bible_sessions/bloc/priest_bible_bloc.dart",        "BLoC for priest-hosted bible sessions",         "PriestBibleBloc"),
    ("features/priest/bible_sessions/pages/priest_bible_page.dart",       "Bible session hosting screen for priests",      "PriestBiblePage"),
    ("features/priest/bible_sessions/widgets/priest_bible_widgets.dart",  "Widgets for the priest bible sessions feature", "PriestBibleWidgets"),
    # priest/profile
    ("features/priest/profile/bloc/priest_profile_bloc.dart",        "BLoC for priest profile state management",  "PriestProfileBloc"),
    ("features/priest/profile/pages/priest_profile_page.dart",       "Profile view and edit screen for priests",  "PriestProfilePage"),
    ("features/priest/profile/widgets/priest_profile_widgets.dart",  "Widgets for the priest profile feature",    "PriestProfileWidgets"),
    # admin/dashboard
    ("features/admin/dashboard/bloc/admin_dashboard_bloc.dart",        "BLoC for admin dashboard state",              "AdminDashboardBloc"),
    ("features/admin/dashboard/pages/admin_dashboard_page.dart",       "Main dashboard screen for the admin role",    "AdminDashboardPage"),
    ("features/admin/dashboard/widgets/admin_dashboard_widgets.dart",  "Widgets for the admin dashboard feature",     "AdminDashboardWidgets"),
    # admin/speakers
    ("features/admin/speakers/bloc/speakers_bloc.dart",        "BLoC for managing speakers in admin",        "SpeakersBloc"),
    ("features/admin/speakers/pages/speakers_page.dart",       "Speakers management screen for admins",      "SpeakersPage"),
    ("features/admin/speakers/widgets/speakers_widgets.dart",  "Widgets for the admin speakers feature",     "SpeakersWidgets"),
    # admin/users
    ("features/admin/users/bloc/admin_users_bloc.dart",        "BLoC for user management in admin panel",    "AdminUsersBloc"),
    ("features/admin/users/pages/admin_users_page.dart",       "User management screen for admins",          "AdminUsersPage"),
    ("features/admin/users/widgets/admin_users_widgets.dart",  "Widgets for the admin users feature",        "AdminUsersWidgets"),
    # admin/matrimony
    ("features/admin/matrimony/bloc/admin_matrimony_bloc.dart",        "BLoC for matrimony profile management in admin",  "AdminMatrimonyBloc"),
    ("features/admin/matrimony/pages/admin_matrimony_page.dart",       "Matrimony management screen for admins",           "AdminMatrimonyPage"),
    ("features/admin/matrimony/widgets/admin_matrimony_widgets.dart",  "Widgets for the admin matrimony feature",          "AdminMatrimonyWidgets"),
    # admin/reports
    ("features/admin/reports/bloc/reports_bloc.dart",        "BLoC for reports and analytics state",        "ReportsBloc"),
    ("features/admin/reports/pages/reports_page.dart",       "Reports and analytics screen for admins",     "ReportsPage"),
    ("features/admin/reports/widgets/reports_widgets.dart",  "Widgets for the admin reports feature",       "ReportsWidgets"),
    # admin/revenue
    ("features/admin/revenue/bloc/revenue_bloc.dart",        "BLoC for revenue tracking state",             "RevenueBloc"),
    ("features/admin/revenue/pages/revenue_page.dart",       "Revenue overview screen for admins",          "RevenuePage"),
    ("features/admin/revenue/widgets/revenue_widgets.dart",  "Widgets for the admin revenue feature",       "RevenueWidgets"),
    # admin/settings
    ("features/admin/settings/bloc/settings_bloc.dart",        "BLoC for app settings state management",   "SettingsBloc"),
    ("features/admin/settings/pages/settings_page.dart",       "App settings screen for admins",           "SettingsPage"),
    ("features/admin/settings/widgets/settings_widgets.dart",  "Widgets for the admin settings feature",   "SettingsWidgets"),
    # admin/withdrawals
    ("features/admin/withdrawals/bloc/withdrawals_bloc.dart",        "BLoC for withdrawal requests state",               "WithdrawalsBloc"),
    ("features/admin/withdrawals/pages/withdrawals_page.dart",       "Withdrawal requests management screen for admins", "WithdrawalsPage"),
    ("features/admin/withdrawals/widgets/withdrawals_widgets.dart",  "Widgets for the admin withdrawals feature",        "WithdrawalsWidgets"),
]

for rel_path, comment, classname in files:
    full_path = os.path.join(BASE, rel_path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    with open(full_path, "w") as fh:
        fh.write(f"// {comment}\n\nclass {classname} {{}}\n")

print(f"Created {len(files)} files successfully.")
