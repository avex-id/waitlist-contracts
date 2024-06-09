module mini_games::coin_flip {

    use std::signer;
    use std::vector;
    use std::string::{String};

    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::type_info;
    use aptos_framework::randomness;


    use mini_games::resource_account_manager as resource_account;
    use mini_games::house_treasury;

    /// you are not authorized to call this function
    const E_ERROR_UNAUTHORIZED: u64 = 1;
    /// sum of the dice is out of bounds
    const E_DICE_SUM_OUT_OF_BOUNDS: u64 = 2;
    /// the game for the coin type does not exist
    const E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST: u64 = 3;
    /// the game is paused
    const E_GAME_PAUSED: u64 = 4;
    /// the bet amount is invalid
    const E_ERROR_INVALID_BET_AMOUNTS: u64 = 5;
    /// the bet amount exceeds the max bet amount
    const E_ERROR_BET_AMOUNT_EXCEEDS_MAX: u64 = 6;
    /// the bet amount is below the min bet amount
    const E_ERROR_BET_AMOUNT_BELOW_MIN: u64 = 7;
    /// the coin type is invalid
    const E_ERROR_INVALID_COIN: u64 = 8;
    /// the game for the coin type already exists
    const E_GAME_FOR_COIN_TYPE_DOES_ALREADY_EXIST: u64 = 9;
    /// allowed bet types are : 0, 1
    const E_ERROR_INVALID_BET_TYPE: u64 = 10;


    const EVEN_ODD_MULTIPLIER : u64 = 150;
    const DIVISOR : u64 = 100;

    const HEADS : u64 = 0;
    const TAILS : u64 = 1;


    #[event]
    struct PlayEvent has drop, store {
        bet_multiplier_numerator : u64,
        bet_multiplier_denominator : u64,
        player : address,
        is_winner : bool,
        bet_coin_type: String,
        bet_amount: u64,
        amount_won: u64,
        selected_coin_face: u64,
        outcome_coin_face: u64
    }

    struct GameManager<phantom CoinType> has key {
        active: bool,
        max_bet_amount: u64,
        min_bet_amount: u64,
        win_multiplier_numerator: u64,
        win_multiplier_denominator: u64,
        counter: u64, // TODO: remove before production
        // defy_coins_exchange_rate: u64,
    }

    struct PlayerRewards<phantom CoinType> has key {
        rewards_balance : Coin<CoinType>,
        num_plays: u64
    }

    public entry fun add_new_game<CoinType>(
        sender: &signer,
        max_bet_amount: u64,
        min_bet_amount: u64,
        win_multiplier_numerator: u64,
        win_multiplier_denominator: u64
        // 1 defy coin == defy_coins_exchange_rate CoinType
        // defy_coins_exchange_rate: u64
    ) {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(!exists<GameManager<CoinType>>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_ALREADY_EXIST);
        move_to(&resource_account::get_signer(), GameManager<CoinType> {
            active: true,
            max_bet_amount,
            min_bet_amount,
            counter: 0,
            win_multiplier_numerator,
            win_multiplier_denominator,
            // defy_coins_exchange_rate
        });
    }

    public entry fun pause_game<CoinType>(
        sender: &signer
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.active = false;
    }

    public entry fun resume_game<CoinType>(
        sender: &signer
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.active = true;
    }

    public entry fun set_max_and_min_bet_amount<CoinType>(
        sender: &signer,
        max_bet_amount: u64,
        min_bet_amount: u64
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.max_bet_amount = max_bet_amount;
        game_manager.min_bet_amount = min_bet_amount;
    }

    public entry fun set_win_multiplier<CoinType>(
        sender: &signer,
        win_multiplier_numerator: u64,
        win_multiplier_denominator: u64
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        game_manager.win_multiplier_numerator = win_multiplier_numerator;
        game_manager.win_multiplier_denominator = win_multiplier_denominator;
    }

    // public entry fun set_defy_coin_exchange_value<CoinType>(
    //     sender: &signer,
    //     defy_coins_exchange_rate: u64
    // ) acquires GameManager {
    //     assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
    //     let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
    //     game_manager.defy_coins_exchange_rate = defy_coins_exchange_rate;
    // }

    entry fun play_multiple<CoinType>(
        sender: &signer,
        selected_coin_face: u64, // TODO: can shift this to vector is  nedded
        bet_amount: u64,
        num_plays: u64
    ) acquires GameManager, PlayerRewards {
        for (i in 0..num_plays) {
            play<CoinType>(sender, selected_coin_face, bet_amount);
        }
    }

    entry fun play<CoinType>(
        sender: &signer,
        selected_coin_face: u64, // 0 - heads, 1 - tails
        bet_amount: u64,
    ) acquires GameManager, PlayerRewards {
        assert!(exists<GameManager<CoinType>>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST);

        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        assert!(game_manager.active, E_GAME_PAUSED);
        assert!(bet_amount <= game_manager.max_bet_amount, E_ERROR_BET_AMOUNT_EXCEEDS_MAX);
        assert!(bet_amount >= game_manager.min_bet_amount, E_ERROR_BET_AMOUNT_BELOW_MIN);

        let bet_coins = coin::withdraw<CoinType>(sender, bet_amount);
        house_treasury::merge_coins(bet_coins);

        let coin_flip_value = randomness::u64_range(0, 2);

        handle_roll<CoinType>(sender, coin_flip_value, selected_coin_face, bet_amount);

    }

    entry fun claim<X, Y, Z, A, B>(sender: &signer, num_coins : u64)
    acquires PlayerRewards {

        if (num_coins >= 1){
            assert!(exists<PlayerRewards<X>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<X>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins  >= 2){
            assert!(exists<PlayerRewards<Y>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<Y>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins >= 3){
            assert!(exists<PlayerRewards<Z>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<Z>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins >= 4){
            assert!(exists<PlayerRewards<A>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<A>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };

        if (num_coins >= 5){

            assert!(exists<PlayerRewards<B>>(signer::address_of(sender)), E_ERROR_INVALID_COIN);
            let player_rewards = borrow_global_mut<PlayerRewards<B>>(signer::address_of(sender));
            let reward_coins = &mut player_rewards.rewards_balance;
            let value = coin::value(reward_coins);
            let coins = coin::extract(reward_coins, value);
            aptos_account::deposit_coins(signer::address_of(sender), coins);
        };
    }



    fun handle_roll<CoinType>(
        sender: &signer,
        coin_flip_value: u64,
        selected_coin_face: u64,
        bet_amount: u64
    ) acquires GameManager, PlayerRewards {

        if(!exists<PlayerRewards<CoinType>>(signer::address_of(sender))){
            move_to(sender, PlayerRewards<CoinType> {
                rewards_balance: coin::zero<CoinType>(),
                num_plays: 0
            });
        };

        let game_manager = borrow_global_mut<GameManager<CoinType>>(resource_account::get_address());
        // let defy_coins_exchange_rate = game_manager.defy_coins_exchange_rate;
        let player_rewards = borrow_global_mut<PlayerRewards<CoinType>>(signer::address_of(sender));
        player_rewards.num_plays = player_rewards.num_plays + 1;

        if (selected_coin_face == coin_flip_value){
            let muliplier_num = game_manager.win_multiplier_numerator;
            let muliplier_den = game_manager.win_multiplier_denominator;

            let amount_won = (bet_amount * muliplier_num) / muliplier_den;
            let coin = house_treasury::extract_coins<CoinType>(amount_won);
            coin::merge(&mut player_rewards.rewards_balance, coin);

            emit_play_event(muliplier_num, muliplier_den, signer::address_of(sender), true,  type_info::type_name<CoinType>(), bet_amount, amount_won, selected_coin_face, coin_flip_value);
        }  else {
            emit_play_event(0, 0, signer::address_of(sender), false,  type_info::type_name<CoinType>(), bet_amount, 0, selected_coin_face, coin_flip_value);
        };

    }


    fun add_coins_to_player_rewards_and_calculate_defy_coins_won<CoinType>(
        amount_won : u64,
        player_rewards: &mut PlayerRewards<CoinType>,
        defy_coins_exchange_rate: u64,
        total_bet_coins: u64
    ) : u64 {
        let defy_coins_won = if (amount_won > 0) {
            let coin = house_treasury::extract_coins<CoinType>(amount_won);
            coin::merge(&mut player_rewards.rewards_balance, coin);
            0
        } else{
            total_bet_coins / defy_coins_exchange_rate
        };
        defy_coins_won
    }

    fun bytes_to_u64(bytes: vector<u8>): u64 {
        let value    = 0u64;
        let i = 0u64;
        while (i < 8) {
            value = value | ((*vector::borrow(&bytes, i) as u64) << ((8 * (7 - i)) as u8));
            i = i + 1;
        };
        return value
    }


    fun emit_play_event(
        bet_multiplier_numerator : u64,
        bet_multiplier_denominator : u64,
        player : address,
        is_winner : bool,
        bet_coin_type: String,
        bet_amount: u64,
        amount_won: u64,
        selected_coin_face: u64,
        outcome_coin_face: u64
    ) {
        0x1::event::emit(PlayEvent {
            bet_multiplier_numerator,
            bet_multiplier_denominator,
            player,
            is_winner,
            bet_coin_type,
            bet_amount,
            amount_won,
            selected_coin_face,
            outcome_coin_face
        });
    }


    #[view]
    public fun see_resource_address(): address {
        resource_account::get_address()
    }

}