module order_book::book {
    use std::vector;
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;

    use order_book::order::{Self, Ask, Bid, Order, Orders};
    use order_book::wallet::{Self, Locked, Unlocked, Wallet, Wallets};

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
        let quote_transfer = order::price(&order) * order::quantity(&order);

        let unfilled = wallet::withdraw_unlocked(user, &mut book.quote_wallets, quote_transfer);
        let filled = match_bid(book, &mut order, &mut unfilled);

        let locked = wallet::swap<Quote, Unlocked, Locked>(unfilled);
        wallet::deposit_locked(order::user_cap(&order), &mut book.quote_wallets, locked);
        wallet::deposit_unlocked(order::user_cap(&order), &mut book.base_wallets, filled);

        order::add_order(&mut book.bids, order);
    }

    /// Place a new ask order.
    ///
    /// This will first match against existing bids, then add a new order for the remainder.
    public fun place_ask<Base, Quote>(book: &mut Book<Base, Quote>, order: Order<Ask>) {
        let user = order::user_cap(&order);
        let base_transfer = order::quantity(&order);

        let unfilled = wallet::withdraw_unlocked(user, &mut book.base_wallets, base_transfer);
        let filled = match_ask(book, &mut order, &mut unfilled);

        let locked = wallet::swap<Base, Unlocked, Locked>(unfilled);
        wallet::deposit_locked(order::user_cap(&order), &mut book.base_wallets, locked);
        wallet::deposit_unlocked(order::user_cap(&order), &mut book.quote_wallets, filled);

        order::add_order(&mut book.asks, order);
    }

    /// Match a bid order against existing asks, returning a filled Base wallet with matches.
    fun match_bid<Base, Quote>(
        book: &mut Book<Base, Quote>,
        order: &mut Order<Bid>,
        unfilled: &mut Wallet<Quote, Unlocked>,
    ): Wallet<Base, Unlocked> {
        let filled = wallet::new_wallet<Base, Unlocked>();
        let bid_price = order::price(order);
        let remaining = order::quantity(order);

        let ticks = order::ticks_mut(&mut book.asks);
        let (tick_index, tick_len) = (0, vector::length(ticks));

        while (tick_index < tick_len && remaining > 0) {
            let tick = vector::borrow_mut(ticks, tick_index);
            let ask_price = order::tick_price(tick);
            if (ask_price > bid_price) break;

            let orders = order::orders_mut(tick);
            let (orders_index, orders_len) = (0, vector::length(orders));

            while (orders_index < orders_len && remaining > 0) {
                let ask_order = vector::borrow_mut(orders, orders_index);
                let ask_user = order::user_cap(ask_order);
                let ask_quantity = order::quantity(ask_order);

                let matched_quantity = if (remaining > ask_quantity) { ask_quantity } else { remaining };
                let quote_transfer = ask_price * matched_quantity;
                let quote_unlocked = wallet::split(unfilled, quote_transfer);
                wallet::deposit_unlocked(ask_user, &mut book.quote_wallets, quote_unlocked);

                let base_locked = wallet::withdraw_locked(ask_user, &mut book.base_wallets, matched_quantity);
                let base_unlocked = wallet::swap<Base, Locked, Unlocked>(base_locked);
                wallet::join(&mut filled, base_unlocked);

                order::set_quantity(ask_order, ask_quantity - matched_quantity);
                remaining = remaining - matched_quantity;
                orders_index = orders_index + 1;
            };

            tick_index = tick_index + 1;
        };

        order::set_quantity(order, remaining);
        filled
    }

    /// Match an ask order against existing bids, returning a filled Quote wallet with matches.
    fun match_ask<Base, Quote>(
        book: &mut Book<Base, Quote>,
        order: &mut Order<Ask>,
        unfilled: &mut Wallet<Base, Unlocked>,
    ): Wallet<Quote, Unlocked> {
        let filled = wallet::new_wallet<Quote, Unlocked>();
        let ask_price = order::price(order);
        let remaining = order::quantity(order);

        let ticks = order::ticks_mut(&mut book.bids);
        let tick_index = vector::length(ticks);

        while (tick_index > 0 && remaining > 0) {
            let tick = vector::borrow_mut(ticks, tick_index - 1);
            let bid_price = order::tick_price(tick);
            if (bid_price < ask_price) break;

            let orders = order::orders_mut(tick);
            let (orders_index, orders_len) = (0, vector::length(orders));

            while (orders_index < orders_len && remaining > 0) {
                let bid_order = vector::borrow_mut(orders, orders_index);
                let bid_user = order::user_cap(bid_order);
                let bid_quantity = order::quantity(bid_order);

                let matched_quantity = if (remaining > bid_quantity) { bid_quantity } else { remaining };
                let base_unlocked = wallet::split(unfilled, matched_quantity);
                wallet::deposit_unlocked(bid_user, &mut book.base_wallets, base_unlocked);

                let quote_transfer = bid_price * matched_quantity;
                let quote_locked = wallet::withdraw_locked(bid_user, &mut book.quote_wallets, quote_transfer);
                let quote_unlocked = wallet::swap<Quote, Locked, Unlocked>(quote_locked);
                wallet::join(&mut filled, quote_unlocked);

                order::set_quantity(bid_order, bid_quantity - matched_quantity);
                remaining = remaining - matched_quantity;
                orders_index = orders_index + 1;
            };

            tick_index = tick_index - 1;
        };

        order::set_quantity(order, remaining);
        filled
    }

    #[test_only]
    use sui::test_scenario as test;
    #[test_only]
    use sui::test_utils::{assert_eq, destroy};

    #[test_only]
    struct EUR {}
    #[test_only]
    struct USD {}

    #[test_only]
    fun new_test_user<Base, Quote>(
        book: &mut Book<Base, Quote>,
        base_balance: u64,
        quote_balance: u64,
        ctx: &mut TxContext
    ): (wallet::UserCap, wallet::UserId) {
        let (user_cap, user_id) = wallet::new_test_user(ctx);
        wallet::init_user_wallets<Base>(&user_cap, &mut book.base_wallets);
        wallet::init_user_wallets<Quote>(&user_cap, &mut book.quote_wallets);

        let base = wallet::new_test_wallet<Base, Unlocked>(base_balance);
        let quote = wallet::new_test_wallet<Quote, Unlocked>(quote_balance);
        wallet::deposit_unlocked(&user_cap, &mut book.base_wallets, base);
        wallet::deposit_unlocked(&user_cap, &mut book.quote_wallets, quote);

        (user_cap, user_id)
    }

    #[test]
    fun test_match_bids_and_asks() {
        let scenario = test::begin(@0x1);
        let ctx = test::ctx(&mut scenario);

        let book = new_book<EUR, USD>(ctx);
        assert_eq(vector::length(order::ticks(&book.bids)), 0);
        assert_eq(vector::length(order::ticks(&book.asks)), 0);

        // user 1 has 1000 USD and places a bid for 10 EUR at a price of 3 USD/EUR
        let (user1_cap, user1_id) = new_test_user<EUR, USD>(&mut book, 0, 1000, ctx);
        place_bid(&mut book, order::new_order<Bid>(user1_cap, 3, 10));
        assert_eq(vector::length(order::ticks(&book.bids)), 1);
        assert_eq(vector::length(order::ticks(&book.asks)), 0);

        // user 1 should now have 30 USD locked, and 970 USD unlocked
        assert_eq(wallet::locked_balance(&book.base_wallets, &user1_id), 0);
        assert_eq(wallet::unlocked_balance(&book.base_wallets, &user1_id), 0);
        assert_eq(wallet::locked_balance(&book.quote_wallets, &user1_id), 30);
        assert_eq(wallet::unlocked_balance(&book.quote_wallets, &user1_id), 970);

        test::next_tx(&mut scenario, @0x2);
        let ctx = test::ctx(&mut scenario);

        // user 2 has 500 EUR and places an ask for 15 USD at a price of 3 USD/EUR
        let (user2_cap, user2_id) = new_test_user<EUR, USD>(&mut book, 500, 0, ctx);
        place_ask(&mut book, order::new_order<Ask>(user2_cap, 3, 5));
        assert_eq(vector::length(order::ticks(&book.bids)), 1);
        assert_eq(vector::length(order::ticks(&book.asks)), 1);

        // user 2 should now have 495 EUR unlocked, and 15 USD unlocked
        assert_eq(wallet::locked_balance(&book.base_wallets, &user2_id), 0);
        assert_eq(wallet::unlocked_balance(&book.base_wallets, &user2_id), 495);
        assert_eq(wallet::locked_balance(&book.quote_wallets, &user2_id), 0);
        assert_eq(wallet::unlocked_balance(&book.quote_wallets, &user2_id), 15);

        // user 1 should now have 5 EUR unlocked, 15 USD locked, and 970 USD unlocked
        assert_eq(wallet::locked_balance(&book.base_wallets, &user1_id), 0);
        assert_eq(wallet::unlocked_balance(&book.base_wallets, &user1_id), 5);
        assert_eq(wallet::locked_balance(&book.quote_wallets, &user1_id), 15);
        assert_eq(wallet::unlocked_balance(&book.quote_wallets, &user1_id), 970);

        test::next_tx(&mut scenario, @0x3);
        let ctx = test::ctx(&mut scenario);

        // user 3 has 100 USD and places an unmatched bid for 5 EUR at a price of 1 USD/EUR
        let (user3_cap, user3_id) = new_test_user<EUR, USD>(&mut book, 0, 100, ctx);
        place_bid(&mut book, order::new_order<Bid>(user3_cap, 1, 5));
        assert_eq(vector::length(order::ticks(&book.bids)), 2);
        assert_eq(vector::length(order::ticks(&book.asks)), 1);

        // user 3 should now have 5 USD locked, and 95 USD unlocked
        assert_eq(wallet::locked_balance(&book.base_wallets, &user3_id), 0);
        assert_eq(wallet::unlocked_balance(&book.base_wallets, &user3_id), 0);
        assert_eq(wallet::locked_balance(&book.quote_wallets, &user3_id), 5);
        assert_eq(wallet::unlocked_balance(&book.quote_wallets, &user3_id), 95);

        test::next_tx(&mut scenario, @0x4);
        let ctx = test::ctx(&mut scenario);

        // user 4 has 200 EUR and places an ask for 100 USD at a price of 2 USD/EUR
        let (user4_cap, user4_id) = new_test_user<EUR, USD>(&mut book, 200, 0, ctx);
        place_ask(&mut book, order::new_order<Ask>(user4_cap, 2, 50));
        assert_eq(vector::length(order::ticks(&book.bids)), 2);
        assert_eq(vector::length(order::ticks(&book.asks)), 2);

        // user 4 should now have 45 EUR locked, 150 EUR unlocked, and 15 USD unlocked
        assert_eq(wallet::locked_balance(&book.base_wallets, &user4_id), 45);
        assert_eq(wallet::unlocked_balance(&book.base_wallets, &user4_id), 150);
        assert_eq(wallet::locked_balance(&book.quote_wallets, &user4_id), 0);
        assert_eq(wallet::unlocked_balance(&book.quote_wallets, &user4_id), 15);

        // user 1 should now have 10 EUR unlocked and 970 USD unlocked
        assert_eq(wallet::locked_balance(&book.base_wallets, &user1_id), 0);
        assert_eq(wallet::unlocked_balance(&book.base_wallets, &user1_id), 10);
        assert_eq(wallet::locked_balance(&book.quote_wallets, &user1_id), 0);
        assert_eq(wallet::unlocked_balance(&book.quote_wallets, &user1_id), 970);

        destroy(book);
        test::end(scenario);
    }
}
