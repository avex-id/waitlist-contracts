module mini_games::coin_flip {

    use std::signer;
    use std::string::{String};
    use aptos_std::type_info;

    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::randomness;


    use mini_games::resource_account_manager as resource_account;
    use mini_games::house_treasury;

    /// you are not authorized to call this function
    const E_ERROR_UNAUTHORIZED: u64 = 1;
    /// the game for the coin type does not exist
    const E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST: u64 = 2;
    /// the game is paused
    const E_GAME_PAUSED: u64 = 3;
    /// the bet amount exceeds the max bet amount
    const E_ERROR_BET_AMOUNT_EXCEEDS_MAX: u64 = 4;
    /// the bet amount is below the min bet amount
    const E_ERROR_BET_AMOUNT_BELOW_MIN: u64 = 5;
    /// the coin type is invalid
    const E_ERROR_INVALID_COIN: u64 = 6;
    /// the game for the coin type already exists
    const E_GAME_FOR_COIN_TYPE_DOES_ALREADY_EXIST: u64 = 7;
    /// allowed bet types are : 0, 1
    const E_ERROR_INVALID_BET_TYPE: u64 = 8;
    /// the number of plays should be less than 8 and greater than 0
    const E_ERROR_NUM_PLAYS_EXCEEDS_BOUNDS: u64 = 9;


    const HEADS : u64 = 0;
    const TAILS : u64 = 1;
    const MAX_PLAY_COUNT : u64 = 8;

    struct GameManager<phantom Heads, phantom Tails> has key {
        active: bool,
        max_bet_amount_heads: u64,
        min_bet_amount_heads: u64,
        max_bet_amount_tails: u64,
        min_bet_amount_tails: u64,
        win_multiplier_numerator: u64,
        win_multiplier_denominator: u64,
        defy_coins_exchange_rate_heads: u64,
        defy_coins_exchange_rate_tails: u64
    }

    struct PlayerRewards<phantom CoinType> has key {
        rewards_balance : Coin<CoinType>,
    }
    struct PlayerDefyCoinsRewards has key {
        rewards_balance : u64,
    }


    #[event]
    struct PlayEvent has drop, store {
        heads_coin: String,
        tales_coin: String,
        selected_side: u64, // 0 - heads, 1 - tails
        outcome_side: u64, // 0 - heads, 1 - tails
        bet_multiplier_numerator : u64,
        bet_multiplier_denominator : u64,
        player : address,
        is_winner : bool,
        bet_amount: u64,
        amount_won: u64,
        defy_coins_won: u64
    }

    #[event]
    struct DefyCoinsClaimEvent has drop, store {
        player : address,
        defy_coins_won: u64
    }



    public entry fun add_new_game<Heads, Tails>(
        sender: &signer,
        active: bool,
        max_bet_amount_heads: u64,
        min_bet_amount_heads: u64,
        max_bet_amount_tails: u64,
        min_bet_amount_tails: u64,
        win_multiplier_numerator: u64,
        win_multiplier_denominator: u64,
        defy_coins_exchange_rate_heads: u64,
        defy_coins_exchange_rate_tails: u64
    ) {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        assert!(!exists<GameManager<Heads, Tails>>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_ALREADY_EXIST);
        move_to(&resource_account::get_signer(), GameManager<Heads, Tails> {
            active,
            max_bet_amount_heads,
            min_bet_amount_heads,
            max_bet_amount_tails,
            min_bet_amount_tails,
            win_multiplier_numerator,
            win_multiplier_denominator,
            defy_coins_exchange_rate_heads,
            defy_coins_exchange_rate_tails
        });
    }

    public entry fun pause_game<Heads, Tails>(
        sender: &signer
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());
        game_manager.active = false;
    }

    public entry fun resume_game<Heads, Tails>(
        sender: &signer
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());
        game_manager.active = true;
    }

    public entry fun set_max_and_min_bet_amount<Heads, Tails>(
        sender: &signer,
        max_bet_amount_heads: u64,
        min_bet_amount_heads: u64,
        max_bet_amount_tails: u64,
        min_bet_amount_tails: u64,
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());
        game_manager.max_bet_amount_heads = max_bet_amount_heads;
        game_manager.min_bet_amount_heads = min_bet_amount_heads;
        game_manager.max_bet_amount_tails = max_bet_amount_tails;
        game_manager.min_bet_amount_tails = min_bet_amount_tails;
    }

    public entry fun set_win_multiplier<Heads, Tails>(
        sender: &signer,
        win_multiplier_numerator: u64,
        win_multiplier_denominator: u64
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());
        game_manager.win_multiplier_numerator = win_multiplier_numerator;
        game_manager.win_multiplier_denominator = win_multiplier_denominator;
    }

    public entry fun set_defy_coin_exchange_value<Heads, Tails>(
        sender: &signer,
        defy_coins_exchange_rate_heads: u64,
        defy_coins_exchange_rate_tails: u64
    ) acquires GameManager {
        assert!(signer::address_of(sender) == @mini_games, E_ERROR_UNAUTHORIZED);
        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());
        game_manager.defy_coins_exchange_rate_heads = defy_coins_exchange_rate_heads;
        game_manager.defy_coins_exchange_rate_tails = defy_coins_exchange_rate_tails;
    }

    #[randomness]
    entry fun play_multiple<Heads, Tails>(
        sender: &signer,
        selected_coin_face: u64, // 0 - heads, 1 - tails
        bet_amount: u64,
        num_plays: u64
    ) acquires GameManager, PlayerRewards, PlayerDefyCoinsRewards {
        assert!(num_plays <= MAX_PLAY_COUNT, E_ERROR_NUM_PLAYS_EXCEEDS_BOUNDS);
        assert!(num_plays >= 1, E_ERROR_NUM_PLAYS_EXCEEDS_BOUNDS);
        for (i in 0..num_plays) {
            play<Heads, Tails>(sender, selected_coin_face, bet_amount);
        }
    }

    #[randomness]
    entry fun play<Heads, Tails>(
        sender: &signer,
        selected_coin_face: u64, // 0 - heads, 1 - tails
        bet_amount: u64,
    ) acquires GameManager, PlayerRewards, PlayerDefyCoinsRewards{
        assert!(exists<GameManager<Heads, Tails>>(resource_account::get_address()), E_GAME_FOR_COIN_TYPE_DOES_NOT_EXIST);

        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());
        assert!(game_manager.active, E_GAME_PAUSED);

        if (selected_coin_face == HEADS){
            assert!(bet_amount <= game_manager.max_bet_amount_heads, E_ERROR_BET_AMOUNT_EXCEEDS_MAX);
            assert!(bet_amount >= game_manager.min_bet_amount_heads, E_ERROR_BET_AMOUNT_BELOW_MIN);

            let bet_coins = coin::withdraw<Heads>(sender, bet_amount);
            house_treasury::merge_coins<Heads>(bet_coins);

            let coin_flip_value = randomness::u64_range(0, 2);

            handle_roll<Heads, Tails>(sender, coin_flip_value, selected_coin_face, bet_amount);

        } else if (selected_coin_face == TAILS){
            assert!(bet_amount <= game_manager.max_bet_amount_tails, E_ERROR_BET_AMOUNT_EXCEEDS_MAX);
            assert!(bet_amount >= game_manager.min_bet_amount_tails, E_ERROR_BET_AMOUNT_BELOW_MIN);

            let bet_coins = coin::withdraw<Tails>(sender, bet_amount);
            house_treasury::merge_coins<Tails>(bet_coins);

            let coin_flip_value = randomness::u64_range(0, 2);

            handle_roll<Heads, Tails>(sender, coin_flip_value, selected_coin_face, bet_amount);

        } else {
            assert!(false, E_ERROR_INVALID_BET_TYPE);
        };
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



    fun handle_roll<Heads, Tails>(
        sender: &signer,
        coin_flip_value: u64,
        selected_coin_face: u64,
        bet_amount: u64
    ) acquires GameManager, PlayerRewards, PlayerDefyCoinsRewards {
        if(!exists<PlayerRewards<Heads>>(signer::address_of(sender))){
            move_to(sender, PlayerRewards<Heads> {
                rewards_balance: coin::zero<Heads>()
            });
        };

        if(!exists<PlayerRewards<Tails>>(signer::address_of(sender))){
            move_to(sender, PlayerRewards<Tails> {
                rewards_balance: coin::zero<Tails>()
            });
        };

        if(!exists<PlayerDefyCoinsRewards>(signer::address_of(sender))){
            move_to(sender, PlayerDefyCoinsRewards {
                rewards_balance: 0,
            });
        };

        let game_manager = borrow_global_mut<GameManager<Heads, Tails>>(resource_account::get_address());


        if ( selected_coin_face == coin_flip_value && selected_coin_face == HEADS){
            let player_rewards = borrow_global_mut<PlayerRewards<Heads>>(signer::address_of(sender));

            let amount_won = (bet_amount * game_manager.win_multiplier_numerator) / game_manager.win_multiplier_denominator;
            let coin = house_treasury::extract_coins<Heads>(amount_won);
            coin::merge(&mut player_rewards.rewards_balance, coin);

            emit_play_event(type_info::type_name<Heads>(), type_info::type_name<Tails>(), game_manager.win_multiplier_numerator, game_manager.win_multiplier_denominator, signer::address_of(sender), true, bet_amount, amount_won, selected_coin_face, coin_flip_value, 0);
        } else if (selected_coin_face == coin_flip_value && selected_coin_face == TAILS){
            let player_rewards = borrow_global_mut<PlayerRewards<Tails>>(signer::address_of(sender));

            let amount_won = (bet_amount * game_manager.win_multiplier_numerator) / game_manager.win_multiplier_denominator;
            let coin = house_treasury::extract_coins<Tails>(amount_won);
            coin::merge(&mut player_rewards.rewards_balance, coin);

            emit_play_event(type_info::type_name<Heads>(), type_info::type_name<Tails>(), game_manager.win_multiplier_numerator, game_manager.win_multiplier_denominator, signer::address_of(sender), true, bet_amount, amount_won, selected_coin_face, coin_flip_value, 0);
        } else {
            let player_rewards = borrow_global_mut<PlayerDefyCoinsRewards>(signer::address_of(sender));
            let defy_coins_won  = if (selected_coin_face == HEADS){
                let defy_coins_won = (bet_amount / game_manager.defy_coins_exchange_rate_heads);
                player_rewards.rewards_balance = player_rewards.rewards_balance + defy_coins_won;
                defy_coins_won
            } else if (selected_coin_face == TAILS){
                let defy_coins_won = (bet_amount / game_manager.defy_coins_exchange_rate_tails);
                player_rewards.rewards_balance = player_rewards.rewards_balance + defy_coins_won;
                defy_coins_won
            } else {
                0
            };
            emit_play_event(type_info::type_name<Heads>(), type_info::type_name<Tails>(), 0, 0, signer::address_of(sender), false, bet_amount, 0, selected_coin_face, coin_flip_value, defy_coins_won);
        };
    }



    fun emit_play_event(
        heads_coin: String,
        tales_coin: String,
        bet_multiplier_numerator : u64,
        bet_multiplier_denominator : u64,
        player : address,
        is_winner : bool,
        bet_amount: u64,
        amount_won: u64,
        selected_side: u64,
        outcome_side: u64,
        defy_coins_won: u64
    ) {
        0x1::event::emit(PlayEvent {
            heads_coin,
            tales_coin,
            selected_side,
            outcome_side,
            bet_multiplier_numerator,
            bet_multiplier_denominator,
            player,
            is_winner,
            bet_amount,
            amount_won,
            defy_coins_won
        });
    }


    #[view]
    public fun see_resource_address(): address {
        resource_account::get_address()
    }

}