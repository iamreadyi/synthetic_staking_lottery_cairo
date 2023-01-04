%lang starknet
// there is two options to distribute rewards: based on normal balance or squared balance
// use squared balance if you can guarantee sybil resistance
from src.interfaces.i_token import IToken
from src.interfaces.i_staking import IStaking
from lib.cairo_contracts.src.openzeppelin.access.ownable.library import Ownable
from lib.cairo_contracts.src.openzeppelin.security.pausable.library import Pausable

from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.messages import send_message_to_l1
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import (
    get_caller_address,
    get_contract_address,
    get_block_timestamp,
)

from starkware.cairo.common.math import (
    assert_lt,
    unsigned_div_rem,
    assert_nn,
    assert_le,
    assert_not_equal,
    sqrt,
)
from starkware.cairo.common.math_cmp import is_le, is_not_zero, is_nn
from starkware.cairo.common.uint256 import Uint256, uint256_le
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.pow import pow

struct Offer {
    protocol_name: felt,
    protocol_address: felt,
}

const REQUEST_RANDOM = 0;

//
// EVENTS
//

@event
func migrated_called(new_contract_address: felt) {
}

@event
func winner(winner_address: felt, type: felt) {
}

//
// STORAGE
//

@storage_var
func user_id_storage(user_id: felt) -> (user_address: felt) {
}

// it could be a struct for user_address -> id_and_balance struct
@storage_var
func learn_user_id_storage(user_address: felt) -> (user_id: felt) {
}

@storage_var
func user_squared_storage(user_address: felt) -> (user_squared_balance: felt) {
}

@storage_var
func user_balance_storage(user_address: felt) -> (user_balance: felt) {
}
// struct end

@storage_var
func idle_ids_storage(index: felt) -> (idle_id: felt) {
}

@storage_var
func last_idle_id_index_storage() -> (last_idle_id_index: felt) {
}

@storage_var
func sell_slot_idle_id_index_storage() -> (idle_id_index: felt) {
}

@storage_var
func user_count_storage() -> (count: felt) {
}

@storage_var
func pool_proportions_by_100_storage(pool_id: felt) -> (proportion_by_100: felt) {
}

@storage_var
func available_pool_id_storage(index: felt) -> (available_ids: felt) {
}

@storage_var
func pool_count_storage() -> (pool_count: felt) {
}

@storage_var
func staking_protocol_address_storage() -> (protocol_address: felt) {
}

@storage_var
func L1_vrf_bridge_address_storage() -> (contract_address: felt) {
}

@storage_var
func stable_token_address_storage() -> (contract_address: felt) {
}

@storage_var
func offered_storage(index: felt) -> (res: Offer) {
}

@storage_var
func offered_last_index_storage() -> (res: felt) {
}

@storage_var
func lottery_staked_balance_storage() -> (res: felt) {
}

@storage_var
func lottery_squared_balance_storage() -> (res: felt) {
}

//
// CONSTRUCTOR
//

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    owner: felt,
    staking_protocol_address: felt,
    stable_token_address: felt,
    L1_vrf_bridge_address: felt,
) {
    Ownable.initializer(owner);
    last_idle_id_index_storage.write(1);
    sell_slot_idle_id_index_storage.write(1);
    idle_ids_storage.write(1, 1);  // index starts from 1-1
    staking_protocol_address_storage.write(staking_protocol_address);
    stable_token_address_storage.write(stable_token_address);
    L1_vrf_bridge_address_storage.write(L1_vrf_bridge_address);
    return ();
}

//
// VIEW
//

@view
func get_pool_count{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    pool_count: felt
) {
    let (count) = pool_count_storage.read();
    return (pool_count=count);
}

@view
func get_user_balance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user_address: felt
) -> (user_balance: felt) {
    let (balance) = user_balance_storage.read(user_address=user_address);
    return (user_balance=balance);
}

@view
func get_user_squared_balance{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user_address: felt
) -> (user_balance: felt) {
    let (balance) = user_squared_storage.read(user_address=user_address);
    return (user_balance=balance);
}

@view
func learn_user_id{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user_address: felt
) -> (id: felt) {
    let (id) = learn_user_id_storage.read(user_address=user_address);
    return (id=id);
}

@view
func get_idle_id{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(index: felt) -> (
    id: felt
) {
    let (id) = idle_ids_storage.read(index=index);
    return (id=id);
}

//
// EXTERNAL
//

// if all protocols had same interfaces it would be much better
// but for now we have to migrate to add new interfaces

@external
func migrate_to_new_lottery_contract{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(NEW_contract_address: felt) {
    alloc_locals;
    Ownable.assert_only_owner();

    let (stable_address) = stable_token_address_storage.read();
    let (lottery_address) = get_contract_address();

    let (withdraw_amount) = lottery_staked_balance_storage.read();
    let (count) = pool_count_storage.read();
    withdraw_from_pool_by_proportion(
        withdraw_amount=withdraw_amount,
        pool_count=count,
        starter_index=1,
        prop_tracker=0,
        remaining_amount=withdraw_amount,
    );
    let uint256_amount: Uint256 = Uint256(withdraw_amount, 0);
    IToken.transfer(stable_address, NEW_contract_address, uint256_amount);

    migrated_called.emit(new_contract_address=NEW_contract_address);
    return ();
}

@external
func add_new_pool{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pool_id: felt, proportion_by_100: felt
) {
    alloc_locals;
    Ownable.assert_only_owner();

    with_attr error_message("Negative proportion") {
        assert_nn(proportion_by_100);
    }

    let (count) = pool_count_storage.read();
    // index starts from 1
    pool_count_storage.write(count + 1);
    pool_proportions_by_100_storage.write(pool_id=pool_id, value=proportion_by_100);
    available_pool_id_storage.write(index=count + 1, value=pool_id);
    return ();
}

// if owner wants to change proportion to 0, he needs to change other proportions to match 100
// if owner wants change all balances on pools, should set proportion 0 first to withdraw all funds
// then redistribute
@external
func change_pool_proportion{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pool_id: felt, proportion_by_100: felt
) {
    alloc_locals;
    Ownable.assert_only_owner();

    with_attr error_message("Negative proportion") {
        assert_nn(proportion_by_100);
    }

    // to prevent adding new pool
    let (is_zero) = pool_proportions_by_100_storage.read(pool_id=pool_id);

    with_attr error_message("Pool does not exist in lottery contract") {
        assert_not_equal(is_zero, 0);
    }
    // should stay paused until proportions match 100
    pause();
    pool_proportions_by_100_storage.write(pool_id=pool_id, value=proportion_by_100);

    if (proportion_by_100 == 0) {
        let (staking_address) = staking_protocol_address_storage.read();
        let (lottery_address) = get_contract_address();
        let (staked) = IStaking.get_balance_of_staked_token(
            contract_address=staking_address, pair_id=pool_id, user_address=lottery_address
        );
        IStaking.withdraw(contract_address=staking_address, amount=staked, pair_id=pool_id);
        IStaking.get_reward(contract_address=staking_address, pair_id=pool_id);
        return ();
    }

    return ();
}

// if owner wants to send 0 proportion pools funds to other pools he need to call a function
// that function will withdraw funds and get reward then send funds with add_to_pool_by_proportion

// first control if proportions match 100 and after that call this function as owner
@external
func distribute_zero_pools_fund{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    pool_id: felt, proportion_by_100: felt
) {
    alloc_locals;
    Ownable.assert_only_owner();
    Pausable.assert_not_paused();

    let (stable_address) = stable_token_address_storage.read();
    let (lottery_address) = get_contract_address();

    let (balance: Uint256) = IToken.balanceOf(
        contract_address=stable_address, account=lottery_address
    );

    let (count) = pool_count_storage.read();
    // uint to felt conversion, is that good practice?

    add_to_pool_by_proportion(
        deposit_amount=balance.low,
        pool_count=count,
        starter_index=1,
        prop_tracker=0,
        remaining_amount=balance.low,
    );

    return ();
}

// USER SHOULD APPROVE FIRST
// suggest to user to deposit perfect square amount or restrict from front end
// only perfect square numbres can be appreciated fully for quadratic balance
@external
func buy_slot{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    deposit_amount: felt
) {
    alloc_locals;
    Pausable.assert_not_paused();

    with_attr error_message("deposit_amount <= 0") {
        assert_nn(deposit_amount - 1);
    }

    // assert_perfect_square(deposit_amount);

    let (staking_address) = staking_protocol_address_storage.read();
    let (stable_address) = stable_token_address_storage.read();
    let (caller) = get_caller_address();
    let (lottery_address) = get_contract_address();

    let uint256_amount: Uint256 = Uint256(deposit_amount, 0);

    IToken.transferFrom(stable_address, caller, lottery_address, uint256_amount);
    IToken.approve(stable_address, staking_address, uint256_amount);
    let (count) = pool_count_storage.read();
    add_to_pool_by_proportion(
        deposit_amount=deposit_amount,
        pool_count=count,
        starter_index=1,
        prop_tracker=0,
        remaining_amount=deposit_amount,
    );

    let (lot_staked) = lottery_staked_balance_storage.read();
    let (lot_squared) = lottery_squared_balance_storage.read();

    let (user_balance) = user_balance_storage.read(user_address=caller);
    let (user_squared_balance) = user_squared_storage.read(user_address=caller);
    // if user has 0 amount on lottery, contract assigns a new id to user if all previous ids are full
    // if there is a hole in ids, contract assigns an idle id to user
    if (user_balance == 0) {
        let (user_count) = user_count_storage.read();
        user_count_storage.write(user_count + 1);

        user_balance_storage.write(user_address=caller, value=deposit_amount);
        lottery_staked_balance_storage.write(lot_staked + deposit_amount);

        let (idle_id_index) = last_idle_id_index_storage.read();
        let (idle_id) = idle_ids_storage.read(index=idle_id_index);

        if (idle_id == 0) {
            user_id_storage.write(user_id=user_count + 1, value=caller);
            learn_user_id_storage.write(user_address=caller, value=user_count + 1);
            let squared_balance = sqrt(deposit_amount);
            user_squared_storage.write(user_address=caller, value=squared_balance);
            lottery_squared_balance_storage.write(lot_squared + squared_balance);
            return ();
        }

        let (sell_slot_idle_id_index) = sell_slot_idle_id_index_storage.read();

        if (sell_slot_idle_id_index == idle_id_index) {
            last_idle_id_index_storage.write(idle_id_index + 1);

            sell_slot_idle_id_index_storage.write(sell_slot_idle_id_index + 1);
            user_id_storage.write(user_id=idle_id, value=caller);
            learn_user_id_storage.write(user_address=caller, value=idle_id);

            let squared_balance = sqrt(deposit_amount);
            user_squared_storage.write(user_address=caller, value=squared_balance);
            lottery_squared_balance_storage.write(lot_squared + squared_balance);
            return ();
        }
        last_idle_id_index_storage.write(idle_id_index + 1);

        user_id_storage.write(user_id=idle_id, value=caller);
        learn_user_id_storage.write(user_address=caller, value=idle_id);

        let squared_balance = sqrt(deposit_amount);
        user_squared_storage.write(user_address=caller, value=squared_balance);
        lottery_squared_balance_storage.write(lot_squared + squared_balance);
        return ();
    } else {
        user_balance_storage.write(user_address=caller, value=user_balance + deposit_amount);
        lottery_staked_balance_storage.write(lot_staked + deposit_amount);
        let squared_balance = sqrt(deposit_amount);
        user_squared_storage.write(
            user_address=caller, value=squared_balance + user_squared_balance
        );
        lottery_squared_balance_storage.write(lot_squared + squared_balance);
        return ();
    }
}

@external
func sell_slot{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    withdraw_amount: felt
) {
    alloc_locals;
    Pausable.assert_not_paused();

    with_attr error_message("withdraw_amount <= 0") {
        assert_nn(withdraw_amount - 1);
    }

    // assert_perfect_square(withdraw_amount);

    let (staking_address) = staking_protocol_address_storage.read();
    let (stable_address) = stable_token_address_storage.read();
    let (caller) = get_caller_address();
    let (lottery_address) = get_contract_address();

    let (count) = pool_count_storage.read();
    withdraw_from_pool_by_proportion(
        withdraw_amount=withdraw_amount,
        pool_count=count,
        starter_index=1,
        prop_tracker=0,
        remaining_amount=withdraw_amount,
    );

    let (user_balance) = user_balance_storage.read(user_address=caller);
    let remaining_balance = user_balance - withdraw_amount;

    with_attr error_message("You cannot withdraw more than you have") {
        assert_nn(remaining_balance);
    }

    let withdraw_amount_uint: Uint256 = Uint256(withdraw_amount, 0);
    IToken.transfer(stable_address, caller, withdraw_amount_uint);

    let (lot_staked) = lottery_staked_balance_storage.read();
    let (lot_squared) = lottery_squared_balance_storage.read();

    if (remaining_balance == 0) {
        let (user_count) = user_count_storage.read();
        user_count_storage.write(user_count - 1);

        let (sell_idle_id_index) = sell_slot_idle_id_index_storage.read();
        let (idle_id) = idle_ids_storage.read(index=sell_idle_id_index);

        let (user_id) = learn_user_id_storage.read(user_address=caller);
        learn_user_id_storage.write(user_address=caller, value=0);
        user_id_storage.write(user_id=user_id, value=0);

        if (idle_id == 0) {
            idle_ids_storage.write(index=sell_idle_id_index, value=user_id);
            sell_slot_idle_id_index_storage.write(value=sell_idle_id_index + 1);

            user_balance_storage.write(user_address=caller, value=0);
            lottery_staked_balance_storage.write(lot_staked - withdraw_amount);
            user_squared_storage.write(user_address=caller, value=0);
            let squared_withdraw = sqrt(withdraw_amount);
            lottery_squared_balance_storage.write(lot_squared - squared_withdraw);

            return ();
        }

        idle_ids_storage.write(index=sell_idle_id_index + 1, value=user_id);
        sell_slot_idle_id_index_storage.write(value=sell_idle_id_index + 1);

        user_balance_storage.write(user_address=caller, value=0);
        lottery_staked_balance_storage.write(lot_staked - withdraw_amount);
        let squared_withdraw = sqrt(withdraw_amount);
        lottery_squared_balance_storage.write(lot_squared - squared_withdraw);
        user_squared_storage.write(user_address=caller, value=0);

        return ();
    } else {
        // reamining_sqrt could be hacked in a not that harmful way, should be fixed
        user_balance_storage.write(user_address=caller, value=remaining_balance);
        lottery_staked_balance_storage.write(lot_staked - withdraw_amount);
        let remaining_sqrt = sqrt(remaining_balance);
        user_squared_storage.write(user_address=caller, value=remaining_sqrt);
        let squared_withdraw = sqrt(withdraw_amount);
        lottery_squared_balance_storage.write(lot_squared - squared_withdraw);
        return ();
    }
}

@external
func change_VRF_bridge_address{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    NEW_address: felt
) {
    Ownable.assert_only_owner();
    L1_vrf_bridge_address_storage.write(NEW_address);
    return ();
}

// need to call periodically and after that should consume message on L1
// 0 == quadratic, 1 == normal
@external
func distribute_reward_in_time{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    q_or_n: felt
) {
    alloc_locals;
    Ownable.assert_only_owner();
    Pausable.assert_not_paused();

    // quadratic
    if (q_or_n == 0) {
        let (lot_squared) = lottery_squared_balance_storage.read();
        let (L1_CONTRACT_ADDRESS) = L1_vrf_bridge_address_storage.read();

        let (message_payload: felt*) = alloc();

        assert message_payload[0] = REQUEST_RANDOM;
        assert message_payload[1] = lot_squared;
        assert message_payload[2] = q_or_n;

        send_message_to_l1(to_address=L1_CONTRACT_ADDRESS, payload_size=3, payload=message_payload);
        return ();
    } else {
        // normal
        let (lot_staked) = lottery_staked_balance_storage.read();
        let (L1_CONTRACT_ADDRESS) = L1_vrf_bridge_address_storage.read();

        let (message_payload: felt*) = alloc();

        assert message_payload[0] = REQUEST_RANDOM;
        assert message_payload[1] = lot_staked;
        assert message_payload[2] = q_or_n;

        send_message_to_l1(to_address=L1_CONTRACT_ADDRESS, payload_size=3, payload=message_payload);
        return ();
    }
}

//
// BRIDGE HANDLERS
//

@l1_handler
func distribute_with_random{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    from_address: felt, random_number: felt, q_or_n: felt
) {
    let (l1_address) = L1_vrf_bridge_address_storage.read();

    with_attr error_message("l1 address is not compatible") {
        assert l1_address = from_address;
    }

    distribute_reward(random_number=random_number, q_or_n=q_or_n, user_id=1, balance_tracker=0);

    return ();
}

//
// FUNCS
//

// FOR TEST, IT IS EXTERNAL CHANGE IT FOR DEPLOYING
@external
func distribute_reward{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    random_number: felt, q_or_n: felt, user_id: felt, balance_tracker: felt
) {
    alloc_locals;
    Pausable.assert_not_paused();

    if (q_or_n == 0) {
        let (lot_squared) = lottery_squared_balance_storage.read();

        if (balance_tracker == lot_squared) {
            return ();
        }

        let (user_address) = user_id_storage.read(user_id=user_id);
        let (squared_balance) = user_squared_storage.read(user_address);

        let bool = is_le(random_number, balance_tracker + squared_balance);
        if (bool == 1) {
            let (count) = pool_count_storage.read();
            get_reward_and_transfer(user_address=user_address, starter_index=1, pool_count=count);
            winner.emit(winner_address=user_address, type=q_or_n);
            return ();
        } else {
            distribute_reward(
                random_number=random_number,
                q_or_n=q_or_n,
                user_id=user_id + 1,
                balance_tracker=balance_tracker + squared_balance,
            );
            return ();
        }

        // if random number =< balance_tracker + user balance, that user wins
    } else {
        let (lot_staked) = lottery_staked_balance_storage.read();

        if (balance_tracker == lot_staked) {
            return ();
        }

        let (user_address) = user_id_storage.read(user_id=user_id);
        let (staked_balance) = user_balance_storage.read(user_address);

        let bool = is_le(random_number, balance_tracker + staked_balance);
        if (bool == 1) {
            let (count) = pool_count_storage.read();
            get_reward_and_transfer(user_address=user_address, starter_index=1, pool_count=count);
            winner.emit(winner_address=user_address, type=q_or_n);
            return ();
        } else {
            distribute_reward(
                random_number=random_number,
                q_or_n=q_or_n,
                user_id=user_id + 1,
                balance_tracker=balance_tracker + staked_balance,
            );
            return ();
        }
    }
}

func get_reward_and_transfer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    user_address: felt, starter_index: felt, pool_count: felt
) {
    alloc_locals;
    if (pool_count == 0) {
        return ();
    }

    let (available_pool_id) = available_pool_id_storage.read(starter_index);
    let (staking_address) = staking_protocol_address_storage.read();
    IStaking.get_reward(staking_address, available_pool_id);

    let (reward_token_address) = IStaking.get_only_pair_reward_address(
        staking_address, available_pool_id
    );

    let (lottery_address) = get_contract_address();
    let (reward_balance: Uint256) = IToken.balanceOf(reward_token_address, lottery_address);
    IToken.transfer(reward_token_address, user_address, reward_balance);

    get_reward_and_transfer(
        user_address=user_address, starter_index=starter_index + 1, pool_count=pool_count - 1
    );

    return ();
}

func add_to_pool_by_proportion{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    deposit_amount: felt,
    pool_count: felt,
    starter_index: felt,
    prop_tracker: felt,
    remaining_amount: felt,
) {
    alloc_locals;
    if (pool_count == 0) {
        return ();
    }

    let (available_pool_id) = available_pool_id_storage.read(starter_index);
    let (proportion) = pool_proportions_by_100_storage.read(pool_id=available_pool_id);

    if (proportion == 0) {
        add_to_pool_by_proportion(
            deposit_amount=deposit_amount,
            pool_count=pool_count - 1,
            starter_index=starter_index + 1,
            prop_tracker=prop_tracker,
            remaining_amount=remaining_amount,
        );

        return ();
        // when loop comes to last pool we should stake all remaining balance to last pool
        // do it with prop tracker
    } else {
        let (staking_address) = staking_protocol_address_storage.read();
        // to avoid remainder issue
        let is_100 = prop_tracker + proportion;
        if (is_100 == 100) {
            IStaking.stake(
                contract_address=staking_address, amount=remaining_amount, pair_id=available_pool_id
            );
            return ();
        }

        let multiplied_amount = proportion * deposit_amount;
        let (deposit_stake, _) = unsigned_div_rem(multiplied_amount, 100);

        IStaking.stake(
            contract_address=staking_address, amount=deposit_stake, pair_id=available_pool_id
        );

        let remaining = remaining_amount - deposit_stake;

        add_to_pool_by_proportion(
            deposit_amount=deposit_amount,
            pool_count=pool_count - 1,
            starter_index=starter_index + 1,
            prop_tracker=prop_tracker + proportion,
            remaining_amount=remaining,
        );

        return ();
    }
}

func withdraw_from_pool_by_proportion{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr
}(
    withdraw_amount: felt,
    pool_count: felt,
    starter_index: felt,
    prop_tracker: felt,
    remaining_amount: felt,
) {
    alloc_locals;
    if (pool_count == 0) {
        return ();
    }

    let (available_pool_id) = available_pool_id_storage.read(starter_index);
    let (proportion) = pool_proportions_by_100_storage.read(pool_id=available_pool_id);

    if (proportion == 0) {
        withdraw_from_pool_by_proportion(
            withdraw_amount=withdraw_amount,
            pool_count=pool_count - 1,
            starter_index=starter_index + 1,
            prop_tracker=prop_tracker,
            remaining_amount=remaining_amount,
        );

        return ();
        // when loop comes to last pool we should stake all remaining balance to last pool
        // do it with prop tracker
    } else {
        let (staking_address) = staking_protocol_address_storage.read();
        // to avoid remainder issue
        let is_100 = prop_tracker + proportion;
        if (is_100 == 100) {
            IStaking.withdraw(
                contract_address=staking_address, amount=remaining_amount, pair_id=available_pool_id
            );
            return ();
        }

        let multiplied_amount = proportion * withdraw_amount;
        let (withdrawww, _) = unsigned_div_rem(multiplied_amount, 100);

        IStaking.withdraw(
            contract_address=staking_address, amount=withdrawww, pair_id=available_pool_id
        );
        let remaining = remaining_amount - withdrawww;

        withdraw_from_pool_by_proportion(
            withdraw_amount=withdraw_amount,
            pool_count=pool_count - 1,
            starter_index=starter_index + 1,
            prop_tracker=prop_tracker + proportion,
            remaining_amount=remaining,
        );

        return ();
    }
}

// func assert_perfect_square{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
//     check_squared: felt
// ) -> (status: felt) {
//     alloc_locals;
//     let check1 = sqrt(check_squared);
//     let check2 = pow(check1, 2);

// let bool = 10;

// if (check_squared == check2) {
//         bool = 1;
//     } else {
//         bool = 0;
//     }

// with_attr error_message("Only perfect squares are allowed") {
//         assert 1 = bool;
//     }
//     return ();
// }

@external
func transferOwnership{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    newOwner: felt
) {
    Ownable.transfer_ownership(newOwner);
    return ();
}

@external
func pause{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    Ownable.assert_only_owner();
    Pausable._pause();
    return ();
}

@external
func unpause{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
    Ownable.assert_only_owner();
    Pausable._unpause();
    return ();
}

@external
func offer_staking_protocol{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    protocol_name: felt, protocol_address: felt
) {
    let (last) = offered_last_index_storage.read();

    let offer_instance: Offer = Offer(
        protocol_name=protocol_name, protocol_address=protocol_address
    );

    offered_storage.write(index=last, value=offer_instance);

    offered_last_index_storage.write(last + 1);

    return ();
}
