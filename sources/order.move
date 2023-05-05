module order_book::order {
    use std::vector;

    use order_book::wallet::UserCap;

    friend order_book::book;

    const EZeroPrice: u64 = 1;
    const EZeroQuantity: u64 = 2;

    /// A `Bid` order `Side.`
    struct Bid {}
    /// An `Ask` order `Side.`
    struct Ask {}

    /// An `Order` represents a `Bid` or `Ask` at some `price` and `quantity`.
    struct Order<phantom Side> has store {
        user_cap: UserCap,
        price: u64,
        quantity: u64,
    }

    /// Create a new `Order` with the capability to act on behalf of the user.
    public fun new_order<Side>(user_cap: UserCap, price: u64, quantity: u64): Order<Side> {
        assert!(price > 0, EZeroPrice);
        assert!(quantity > 0, EZeroQuantity);

        Order { user_cap, price, quantity }
    }

    /// Returns a reference to `UserCap` to act on their behalf.
    public(friend) fun user_cap<Side>(order: &Order<Side>): &UserCap {
        &order.user_cap
    }

    /// Returns the `Order` price.
    public fun price<Side>(order: &Order<Side>): u64 {
        order.price
    }

    /// Returns the current `Order` quantity.
    public fun quantity<Side>(order: &Order<Side>): u64 {
        order.quantity
    }

    /// Set a new `Order` quantity after matching.
    public(friend) fun set_quantity<Side>(order: &mut Order<Side>, quantity: u64) {
        order.quantity = quantity;
    }

    /// `Tick` is a FIFO list of orders at some tick price.
    struct Tick<phantom Side> has store {
        price: u64,
        orders: vector<Order<Side>>,
    }

    /// Create a new `Tick` at the price of some order.
    public(friend) fun new_tick<Side>(order: Order<Side>): Tick<Side> {
        Tick<Side> {
            price: order.price,
            orders: vector::singleton(order)
        }
    }

    /// Returns the `Tick` price.
    public fun tick_price<Side>(tick: &Tick<Side>): u64 {
        tick.price
    }

    /// Returns a reference to the `Tick` orders.
    public fun orders<Side>(tick: &Tick<Side>): &vector<Order<Side>> {
        &tick.orders
    }

    /// Returns a mutable reference to the `Tick` orders.
    public(friend) fun orders_mut<Side>(tick: &mut Tick<Side>): &mut vector<Order<Side>> {
        &mut tick.orders
    }

    /// `Ticks` is a price-ordered list of `Tick` entries.
    struct Ticks<phantom Side> has store {
        inner: vector<Tick<Side>>,
    }

    /// Create a new `Ticks` object.
    public(friend) fun new_ticks<Side>(): Ticks<Side> {
        Ticks { inner: vector::empty() }
    }

    /// Returns a reference to the inner ticks vector.
    public fun ticks<Side>(ticks: &Ticks<Side>): &vector<Tick<Side>> {
        &ticks.inner
    }

    /// Returns a mutable reference to the inner ticks vector.
    public(friend) fun ticks_mut<Side>(ticks: &mut Ticks<Side>): &mut vector<Tick<Side>> {
        &mut ticks.inner
    }

    /// Add an order to an existing `Tick` at the same price, or a new `Tick` otherwise.
    public(friend) fun add_order<Side>(ticks: &mut Ticks<Side>, order: Order<Side>) {
        let search = binary_search(ticks, order.price);
        let inner = ticks_mut(ticks);

        if (search.is_match) {
            let tick = vector::borrow_mut(inner, search.index);
            vector::push_back(&mut tick.orders, order);
            return
        };

        let tick = new_tick<Side>(order);
        vector::push_back(inner, tick);
        if (search.is_empty) return;

        // move the new order backwards from the end to the correct price position
        let index = vector::length(inner);
        let stop = if (search.is_before) { search.index + 1 } else { search.index + 2 };
        while (index > stop) {
            vector::swap(inner, index - 1, index - 2);
            index = index - 1;
        }
    }

    /// Search a list of ticks for some `target` price.
    fun binary_search<Side>(ticks: &Ticks<Side>, target: u64): Search {
        let left = 0;
        let right = vector::length(&ticks.inner);
        let is_before = false;

        if (right == 0) return search_empty();

        while (left < right) {
            let mid = (left + right) / 2;
            let price = vector::borrow(&ticks.inner, mid).price;

            if (price == target) {
                return search_match(mid)
            } else if (price < target) {
                is_before = false;
                left = mid + 1;
            } else {
                is_before = true;
                right = mid;
            }
        };

        if (is_before) { search_before(left) } else { search_after(right - 1) }
    }

    /// Return value for `binary_search` to work around the lack of sum types.
    struct Search has drop {
        index: u64,
        is_match: bool,
        is_empty: bool,
        is_before: bool,
    }

    fun search_match(index: u64): Search {
        Search { index, is_match: true, is_empty: false, is_before: false }
    }

    fun search_empty(): Search {
        Search { index: 0, is_match: false, is_empty: true, is_before: false }
    }

    fun search_before(index: u64): Search {
        Search { index, is_match: false, is_empty: false, is_before: true }
    }

    fun search_after(index: u64): Search {
        Search { index, is_match: false, is_empty: false, is_before: false }
    }

    #[test_only]
    use sui::test_scenario as test;
    #[test_only]
    use sui::test_utils::{assert_eq, destroy};

    #[test_only]
    use order_book::wallet::new_test_user;

    #[test]
    fun test_add_orders_same_price() {
        let scenario = test::begin(@0x0);
        let ctx = test::ctx(&mut scenario);

        let ticks = new_ticks<Bid>();
        assert_eq(vector::length(&ticks.inner), 0);

        let (user1, _) = new_test_user(ctx);
        let (user2, _) = new_test_user(ctx);

        let price = 100;
        add_order(&mut ticks, new_order<Bid>(user1, price, 10));
        assert_eq(vector::length(&ticks.inner), 1);

        add_order(&mut ticks, new_order<Bid>(user2, price, 20));
        assert_eq(vector::length(&ticks.inner), 1);

        let tick = vector::borrow(&ticks.inner, 0);
        assert_eq(tick.price, price);
        assert_eq(vector::length(&tick.orders), 2);

        let order0 = vector::borrow(&tick.orders, 0);
        let order1 = vector::borrow(&tick.orders, 1);
        assert_eq(order0.price, price);
        assert_eq(order0.quantity, 10);
        assert_eq(order1.price, price);
        assert_eq(order1.quantity, 20);

        destroy(ticks);
        test::end(scenario);
    }

    #[test]
    fun test_tick_price_order() {
        let scenario = test::begin(@0x0);
        let ctx = test::ctx(&mut scenario);

        let ticks = new_ticks<Bid>();
        assert_eq(binary_search(&mut ticks, 0), search_empty());

        let (user1, _) = new_test_user(ctx);
        let (user2, _) = new_test_user(ctx);
        let (user3, _) = new_test_user(ctx);
        let (user4, _) = new_test_user(ctx);

        add_order(&mut ticks, new_order<Bid>(user1, 40, 4));
        assert_eq(binary_search(&mut ticks, 40), search_match(0));
        assert_eq(binary_search(&mut ticks, 35), search_before(0));
        assert_eq(binary_search(&mut ticks, 50), search_after(0));

        add_order(&mut ticks, new_order<Bid>(user2, 50, 5));
        assert_eq(binary_search(&mut ticks, 50), search_match(1));
        assert_eq(binary_search(&mut ticks, 35), search_before(0));
        assert_eq(binary_search(&mut ticks, 45), search_after(0));
        assert_eq(binary_search(&mut ticks, 55), search_after(1));

        add_order(&mut ticks, new_order<Bid>(user3, 20, 2));
        assert_eq(binary_search(&mut ticks, 20), search_match(0));
        assert_eq(binary_search(&mut ticks, 15), search_before(0));
        assert_eq(binary_search(&mut ticks, 35), search_after(0));
        assert_eq(binary_search(&mut ticks, 45), search_before(2));
        assert_eq(binary_search(&mut ticks, 55), search_after(2));

        add_order(&mut ticks, new_order<Bid>(user4, 30, 3));
        assert_eq(binary_search(&mut ticks, 30), search_match(1));
        assert_eq(binary_search(&mut ticks, 15), search_before(0));
        assert_eq(binary_search(&mut ticks, 25), search_after(0));
        assert_eq(binary_search(&mut ticks, 35), search_after(1));
        assert_eq(binary_search(&mut ticks, 45), search_before(3));
        assert_eq(binary_search(&mut ticks, 55), search_after(3));

        assert_eq(vector::borrow(&mut ticks.inner, 0).price, 20);
        assert_eq(vector::borrow(&mut ticks.inner, 1).price, 30);
        assert_eq(vector::borrow(&mut ticks.inner, 2).price, 40);
        assert_eq(vector::borrow(&mut ticks.inner, 3).price, 50);

        destroy(ticks);
        test::end(scenario);
    }
}
