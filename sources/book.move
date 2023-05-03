module order_book::book {
    use std::vector;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;

    use order_book::order::{Self, Ask, Bid, Order, Orders};
    use order_book::wallet::{Self, Locked, Unlocked, Wallet, Wallets};

    struct BookId has store {
        id: UID
    }

    /// An order book for swapping between Base and Quote asset pairs.
    struct Book<phantom Base, phantom Quote> has key, store {
        id: UID,

        bids: Orders<Bid>,
        asks: Orders<Ask>,

        base_wallets: Wallets<Base>,
        quote_wallets: Wallets<Quote>,
    }

    /// Construct a new order book for some Base and Quote asset pairs.
    public(friend) fun new_book<Base, Quote>(ctx: &mut TxContext): Book<Base, Quote> {
        Book<Base, Quote> {
            id: object::new(ctx),

            bids: order::new_orders(),
            asks: order::new_orders(),

            base_wallets: wallet::new_wallets<Base>(ctx),
            quote_wallets: wallet::new_wallets<Quote>(ctx),
        }
    }

    /// Place a new bid order.
    ///
    /// This will first match against existing asks, then add a new order for the remainder.
    public fun place_bid<Base, Quote>(book: &mut Book<Base, Quote>, order: Order<Bid>) {
        let user = order::user_cap(&order);
        let balance = order::price(&order) * order::quantity(&order);

        let unfilled = wallet::withdraw_unlocked(user, &mut book.base_wallets, balance);
        let filled = match_bid(book, &mut order, &mut unfilled);

        let locked = wallet::swap<Base, Unlocked, Locked>(unfilled);
        wallet::deposit_locked(order::user_cap(&order), &mut book.base_wallets, locked);
        wallet::deposit_unlocked(order::user_cap(&order), &mut book.quote_wallets, filled);

        order::add_order(&mut book.bids, order);
    }

    /// Place a new ask order.
    ///
    /// This will first match against existing bids, then add a new order for the remainder.
    public fun place_ask<Base, Quote>(book: &mut Book<Base, Quote>, order: Order<Ask>) {
        let user = order::user_cap(&order);
        let balance = order::quantity(&order);

        let unfilled = wallet::withdraw_unlocked(user, &mut book.quote_wallets, balance);
        let filled = match_ask(book, &mut order, &mut unfilled);

        let locked = wallet::swap<Quote, Unlocked, Locked>(unfilled);
        wallet::deposit_locked(order::user_cap(&order), &mut book.quote_wallets, locked);
        wallet::deposit_unlocked(order::user_cap(&order), &mut book.base_wallets, filled);

        order::add_order(&mut book.asks, order);
    }

    /// Match a bid order against existing asks, returning a filled Quote wallet with matches.
    fun match_bid<Base, Quote>(
        book: &mut Book<Base, Quote>,
        order: &mut Order<Bid>,
        unfilled: &mut Wallet<Base, Unlocked>,
    ): Wallet<Quote, Unlocked> {
        let filled = wallet::new_wallet<Quote, Unlocked>();
        let remaining = order::quantity(order);

        let ticks = order::ticks_mut(&mut book.asks);
        let tick_index = vector::length(ticks);

        while (tick_index > 0 && remaining > 0) {
            let tick = vector::borrow_mut(ticks, tick_index - 1);
            if (order::tick_price(tick) > order::price(order)) break;

            let orders = order::orders_mut(tick);
            let (order_index, order_len) = (0, vector::length(orders));

            while (order_index < order_len && remaining > 0) {
                let ask_order = vector::borrow_mut(orders, order_index);
                let ask_user = order::user_cap(ask_order);
                let ask_price = order::price(ask_order);
                let ask_quantity = order::quantity(ask_order);

                // swap the base quantity from unfilled to ask_user->unlocked
                let base_quantity = if (remaining > ask_quantity) { ask_quantity } else { remaining };
                let base_unlocked = wallet::split(unfilled, base_quantity);
                wallet::deposit_unlocked(ask_user, &mut book.base_wallets, base_unlocked);

                // swap the quote quantity from ask_user->locked to filled
                let quote_quantity = ask_price * base_quantity;
                let quote_locked = wallet::withdraw_locked(ask_user, &mut book.quote_wallets, quote_quantity);
                let quote_unlocked = wallet::swap<Quote, Locked, Unlocked>(quote_locked);
                wallet::join(&mut filled, quote_unlocked);

                order::set_quantity(ask_order, ask_quantity - base_quantity);
                remaining = remaining - base_quantity;
                order_index = order_index + 1;
            };

            tick_index = tick_index - 1;
        };

        order::set_quantity(order, remaining);
        filled
    }

    /// Match an ask order against existing bids, returning a filled Base wallet with matches.
    fun match_ask<Base, Quote>(
        book: &mut Book<Base, Quote>,
        order: &mut Order<Ask>,
        unfilled: &mut Wallet<Quote, Unlocked>,
    ): Wallet<Base, Unlocked> {
        let filled = wallet::new_wallet<Base, Unlocked>();
        let remaining = order::quantity(order);

        let ticks = order::ticks_mut(&mut book.bids);
        let (tick_index, tick_len) = (0, vector::length(ticks));

        while (tick_index < tick_len && remaining > 0) {
            let tick = vector::borrow_mut(ticks, tick_index);
            if (order::tick_price(tick) < order::price(order)) break;

            let orders = order::orders_mut(tick);
            let (order_index, order_len) = (0, vector::length(orders));

            while (order_index < order_len && remaining > 0) {
                let bid_order = vector::borrow_mut(orders, order_index);
                let bid_user = order::user_cap(bid_order);
                let bid_price = order::price(bid_order);
                let bid_quantity = order::quantity(bid_order);

                // swap the quote quantity from unfilled to bid_user->unlocked
                let quote_quantity = if (remaining > bid_quantity) { bid_quantity } else { remaining };
                let quote_unlocked = wallet::split(unfilled, quote_quantity);
                wallet::deposit_unlocked(bid_user, &mut book.quote_wallets, quote_unlocked);

                // swap the base quantity from bid_user->locked to filled
                let base_quantity = bid_price * quote_quantity;
                let base_locked = wallet::withdraw_locked(bid_user, &mut book.base_wallets, base_quantity);
                let base_unlocked = wallet::swap<Base, Locked, Unlocked>(base_locked);
                wallet::join(&mut filled, base_unlocked);

                order::set_quantity(bid_order, bid_quantity - quote_quantity);
                remaining = remaining - quote_quantity;
                order_index = order_index + 1;
            };

            tick_index = tick_index + 1;
        };

        order::set_quantity(order, remaining);
        filled
    }

    #[test_only]
    use sui::test_scenario as test;
    #[test_only]
    use sui::test_utils::{assert_eq, destroy};

    #[test_only]
    struct USD {}
    #[test_only]
    struct EUR {}

    #[test_only]
    fun new_test_user(
        book: &mut Book<USD, EUR>,
        usd_balance: u64,
        eur_balance: u64,
        ctx: &mut TxContext
    ): wallet::UserCap {
        let user = wallet::new_test_user(ctx);
        wallet::init_user_wallets<USD>(&user, &mut book.base_wallets);
        wallet::init_user_wallets<EUR>(&user, &mut book.quote_wallets);

        let usd = wallet::new_test_wallet<USD, Unlocked>(usd_balance);
        let eur = wallet::new_test_wallet<EUR, Unlocked>(eur_balance);
        wallet::deposit_unlocked(&user, &mut book.base_wallets, usd);
        wallet::deposit_unlocked(&user, &mut book.quote_wallets, eur);

        user
    }

    #[test]
    fun test_match_bids_and_asks() {
        let scenario = test::begin(@0x1);
        let ctx = test::ctx(&mut scenario);

        let book = new_book<USD, EUR>(ctx);
        assert_eq(vector::length(order::ticks(&book.bids)), 0);
        assert_eq(vector::length(order::ticks(&book.asks)), 0);

        {
            // user 1 has 1000 USD and places a bid for 10 EUR at a price of 3 USD/EUR
            let user1 = new_test_user(&mut book, 1000, 0, ctx);
            place_bid(&mut book, order::new_order<Bid>(user1, 3, 10));
            assert_eq(vector::length(order::ticks(&book.bids)), 1);
            assert_eq(vector::length(order::ticks(&book.asks)), 0);
        };

        {
            // user 1 should now have 30 USD locked, and 970 USD unlocked
            let bids0 = vector::borrow(order::ticks(&book.bids), 0);
            let bid0 = vector::borrow(order::orders(bids0), 0);
            let user1 = order::user_cap(bid0);

            assert_eq(wallet::locked_balance(user1, &book.base_wallets), 30);
            assert_eq(wallet::unlocked_balance(user1, &book.base_wallets), 970);
            assert_eq(wallet::locked_balance(user1, &book.quote_wallets), 0);
            assert_eq(wallet::unlocked_balance(user1, &book.quote_wallets), 0);
        };

        test::next_tx(&mut scenario, @0x2);
        let ctx = test::ctx(&mut scenario);

        {
            // user 2 has 500 EUR places an ask for 15 USD at a price of 3 USD/EUR
            let user2 = new_test_user(&mut book, 0, 500, ctx);
            place_ask(&mut book, order::new_order<Ask>(user2, 3, 5));
            assert_eq(vector::length(order::ticks(&book.bids)), 1);
            assert_eq(vector::length(order::ticks(&book.asks)), 1);
        };

        {
            // user 2 should now have 495 EUR unlocked, and 15 USD unlocked
            let asks0 = vector::borrow(order::ticks(&book.asks), 0);
            let ask0 = vector::borrow(order::orders(asks0), 0);
            let user2 = order::user_cap(ask0);

            assert_eq(wallet::locked_balance(user2, &book.base_wallets), 0);
            assert_eq(wallet::unlocked_balance(user2, &book.base_wallets), 15);
            assert_eq(wallet::locked_balance(user2, &book.quote_wallets), 0);
            assert_eq(wallet::unlocked_balance(user2, &book.quote_wallets), 495);

        };

        {
            // user 1 should now have 15 USD locked, 970 USD unlocked, and 5 EUR unlocked
            let bids0 = vector::borrow(order::ticks(&book.bids), 0);
            let bid0 = vector::borrow(order::orders(bids0), 0);
            let user1 = order::user_cap(bid0);

            assert_eq(wallet::locked_balance(user1, &book.base_wallets), 15);
            assert_eq(wallet::unlocked_balance(user1, &book.base_wallets), 970);
            assert_eq(wallet::locked_balance(user1, &book.quote_wallets), 0);
            assert_eq(wallet::unlocked_balance(user1, &book.quote_wallets), 5);
        };

        destroy(book);
        test::end(scenario);
    }
}
