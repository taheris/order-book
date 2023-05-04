module order_book::wallet {
    use sui::balance::{Self, Balance};
    use sui::object::{Self, UID, ID};
    use sui::table::{Self, Table};
    use sui::tx_context::TxContext;

    friend order_book::book;

    const EWalletNotFound: u64 = 1;

    /// A `Locked` wallet `Kind`.
    struct Locked {}
    /// An `Unlocked` wallet `Kind`.
    struct Unlocked {}

    /// A capability to act as some user.
    struct UserCap has key, store {
        id: UID
    }

    /// An identifier to some user.
    struct UserId has copy, drop, store {
        id: ID
    }

    /// Create a new capability to act as this user.
    public(friend) fun new_user(ctx: &mut TxContext): UserCap {
        UserCap { id: object::new(ctx) }
    }

    /// Generate a `UserId` from a `UserCap`.
    public(friend) fun user_id(cap: &UserCap): UserId {
        UserId { id: object::uid_to_inner(&cap.id) }
    }

    /// A `Wallet` wraps a `Balance<Coin>` with some wallet `Kind`.
    struct Wallet<phantom Coin, phantom Kind> has store {
        balance: Balance<Coin>,
    }

    /// Create a new wallet that holds balances of `Coin` for some wallet `Kind`.
    public(friend) fun new_wallet<Coin, Kind>(): Wallet<Coin, Kind> {
        Wallet {
            balance: balance::zero<Coin>()
        }
    }

    /// Returns the balance value of the wallet.
    public fun balance<Coin, Kind>(wallet: &Wallet<Coin, Kind>): u64 {
        balance::value(&wallet.balance)
    }

    /// Combine the `from` wallet balance with the `to` wallet balance.
    public(friend) fun join<Coin, Kind>(to: &mut Wallet<Coin, Kind>, from: Wallet<Coin, Kind>) {
        let Wallet { balance } = from;
        balance::join(&mut to.balance, balance);
    }

    /// Split out `amount` from the `from` wallet balance into a new wallet.
    public(friend) fun split<Coin, Kind>(from: &mut Wallet<Coin, Kind>, amount: u64): Wallet<Coin, Kind> {
        let balance = balance::split(&mut from.balance, amount);
        Wallet { balance }
    }

    /// Swap a `Wallet` kind from `KindA` to `KindB`.
    public(friend) fun swap<Coin, KindA, KindB>(wallet: Wallet<Coin, KindA>): Wallet<Coin, KindB> {
        let Wallet { balance } = wallet;
        Wallet<Coin, KindB> { balance }
    }

    /// Mappings from a UserId -> Wallet for each Kind.
    struct Wallets<phantom Coin> has key, store {
        id: UID,
        locked: Table<UserId, Wallet<Coin, Locked>>,
        unlocked: Table<UserId, Wallet<Coin, Unlocked>>
    }

    /// A `Wallets` constructor for some `Coin`.
    public(friend) fun new_wallets<Coin>(ctx: &mut TxContext): Wallets<Coin> {
        Wallets<Coin> {
            id: object::new(ctx),
            locked: table::new(ctx),
            unlocked: table::new(ctx)
        }
    }

    /// Initialize wallets for a user.
    ///
    /// This should be called before deposits and withdrawals.
    public(friend) fun init_user_wallets<Coin>(user_cap: &UserCap, wallets: &mut Wallets<Coin>) {
        let user = user_id(user_cap);
        let locked = new_wallet<Coin, Locked>();
        let unlocked = new_wallet<Coin, Unlocked>();

        table::add(&mut wallets.locked, user, locked);
        table::add(&mut wallets.unlocked, user, unlocked);
    }

    /// Returns the locked balance for a user.
    public fun locked_balance<Coin>(wallets: &Wallets<Coin>, user: &UserId): u64 {
        assert!(table::contains(&wallets.locked, *user), EWalletNotFound);

        let locked = table::borrow(&wallets.locked, *user);
        balance::value(&locked.balance)
    }

    /// Returns the unlocked balance for a user.
    public fun unlocked_balance<Coin>(wallets: &Wallets<Coin>, user: &UserId): u64 {
        assert!(table::contains(&wallets.unlocked, *user), EWalletNotFound);

        let unlocked = table::borrow(&wallets.unlocked, *user);
        balance::value(&unlocked.balance)
    }

    /// Deposit a balance to the user's Locked Wallet.
    public(friend) fun deposit_locked<Coin>(
        user_cap: &UserCap,
        wallets: &mut Wallets<Coin>,
        wallet: Wallet<Coin, Locked>
    ) {
        let user = user_id(user_cap);
        assert!(table::contains(&wallets.locked, *&user), EWalletNotFound);

        let locked = table::borrow_mut(&mut wallets.locked, user);
        join(locked, wallet);
    }

    /// Deposit a balance to the user's Unlocked Wallet.
    public(friend) fun deposit_unlocked<Coin>(
        user_cap: &UserCap,
        wallets: &mut Wallets<Coin>,
        wallet: Wallet<Coin, Unlocked>
    ) {
        let user = user_id(user_cap);
        assert!(table::contains(&wallets.unlocked, *&user), EWalletNotFound);

        let unlocked = table::borrow_mut(&mut wallets.unlocked, user);
        join(unlocked, wallet);
    }

    /// Withdraw coins from a user's Locked Wallet.
    public(friend) fun withdraw_locked<Coin>(
        user_cap: &UserCap,
        wallets: &mut Wallets<Coin>,
        amount: u64
    ): Wallet<Coin, Locked> {
        let user = user_id(user_cap);
        assert!(table::contains(&wallets.locked, *&user), EWalletNotFound);

        let locked = table::borrow_mut(&mut wallets.locked, user);
        split(locked, amount)
    }

    /// Withdraw coins from a user's Unlocked Wallet.
    public(friend) fun withdraw_unlocked<Coin>(
        user_cap: &UserCap,
        wallets: &mut Wallets<Coin>,
        amount: u64
    ): Wallet<Coin, Unlocked> {
        let user = user_id(user_cap);
        assert!(table::contains(&wallets.unlocked, *&user), EWalletNotFound);

        let unlocked = table::borrow_mut(&mut wallets.unlocked, user);
        split(unlocked, amount)
    }

    #[test_only]
    use sui::sui::SUI;
    #[test_only]
    use sui::test_scenario as test;
    #[test_only]
    use sui::test_utils::{assert_eq, destroy};

    #[test_only]
    public fun new_test_user(ctx: &mut TxContext): (UserCap, UserId) {
        let user_cap = new_user(ctx);
        let user_id = user_id(&user_cap);
        (user_cap, user_id)
    }

    #[test_only]
    public(friend) fun new_test_wallet<Coin, Kind>(balance: u64): Wallet<Coin, Kind> {
        Wallet<Coin, Kind> { balance: balance::create_for_testing(balance) }
    }

    #[test]
    fun test_deposit_and_withdraw() {
        let scenario = test::begin(@0x1);
        let ctx = test::ctx(&mut scenario);
        let wallets = new_wallets<SUI>(ctx);

        let (user1_cap, user1_id) = new_test_user(ctx);
        init_user_wallets(&user1_cap, &mut wallets);

        let locked1 = new_test_wallet<SUI, Locked>(0);
        let unlocked1 = new_test_wallet<SUI, Unlocked>(100);
        assert_eq(balance(&locked1), 0);
        assert_eq(balance(&unlocked1), 100);

        deposit_locked(&user1_cap, &mut wallets, locked1);
        deposit_unlocked(&user1_cap, &mut wallets, unlocked1);
        assert_eq(locked_balance(&wallets, &user1_id), 0);
        assert_eq(unlocked_balance(&wallets, &user1_id), 100);

        let withdrawal = withdraw_unlocked(&user1_cap, &mut wallets, 10);
        let withdrawal = swap<SUI, Unlocked, Locked>(withdrawal);
        deposit_locked(&user1_cap, &mut wallets, withdrawal);
        assert_eq(locked_balance(&wallets, &user1_id), 10);
        assert_eq(unlocked_balance(&wallets, &user1_id), 90);

        test::next_tx(&mut scenario, @0x2);
        let (user2_cap, user2_id) = new_test_user(test::ctx(&mut scenario));
        init_user_wallets(&user2_cap, &mut wallets);

        let unlocked2 = new_test_wallet<SUI, Unlocked>(200);
        deposit_unlocked(&user2_cap, &mut wallets, unlocked2);
        assert_eq(unlocked_balance(&wallets, &user2_id), 200);

        destroy(user1_cap);
        destroy(user2_cap);
        destroy(wallets);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sui::balance::ENotEnough)]
    fun test_withdraw_too_much() {
        let scenario = test::begin(@0x1);
        let ctx = test::ctx(&mut scenario);
        let wallets = new_wallets<SUI>(ctx);

        let (user_cap, _user_id) = new_test_user(ctx);
        init_user_wallets(&user_cap, &mut wallets);

        let locked = Wallet<SUI, Locked> { balance: balance::create_for_testing(100) };
        deposit_locked(&user_cap, &mut wallets, locked);

        let attempt = withdraw_locked(&user_cap, &mut wallets, 200);

        destroy(attempt);
        destroy(user_cap);
        destroy(wallets);
        test::end(scenario);
    }
}
