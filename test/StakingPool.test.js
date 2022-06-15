/* eslint no-unused-vars: 0 */
const assert = require('assert');
const { promisify } = require('util');

const StakingPool = artifacts.require('./StakingPool');
const StakingPoolFactory = artifacts.require('./StakingPoolFactory');
const SelfDestruct = artifacts.require('./mocks/SelfDestruct');
require('chai').use(require('chai-as-promised')).should();

const revertError = 'VM Exception while processing transaction: revert';
const toWei = i => web3.utils.toWei(String(i));
const gasPriceMax = 0;
const web3SendAsync = promisify(web3.currentProvider.send);

function txGen(from, value) {
    return {
        from, value, gasPrice: gasPriceMax,
    };
}

async function forceSend(target, value, from) {
    const selfDestruct = await SelfDestruct.new({ value, from });
    await selfDestruct.forceSend(target);
}

let snapshotId;

async function addDaysOnEVM(days) {
    const seconds = days * 3600 * 24;
    await web3SendAsync({
        jsonrpc: '2.0', method: 'evm_increaseTime', params: [seconds], id: 0,
    });
    await web3SendAsync({
        jsonrpc: '2.0', method: 'evm_mine', params: [], id: 0,
    });
}

function snapshotEVM() {
    return web3SendAsync({
        jsonrpc: '2.0', method: 'evm_snapshot', id: Date.now() + 1,
    }).then(({ result }) => { snapshotId = result; });
}

function revertEVM() {
    return web3SendAsync({
        jsonrpc: '2.0', method: 'evm_revert', params: [snapshotId], id: Date.now() + 1,
    });
}

contract('StakingPool', async (accounts) => {
    let pool;
    const miner = accounts[9];
    const minerContactInfo = 'miner@stakingpool';
    const minerFeeBp = 5000;
    const feeBp = 0;
    const feeCollector = accounts[8];
    const treasury = accounts[7];
    const minStakes = toWei(1);
    const maxStakers = 16;
    const startTime = parseInt(Date.now()/1000) + 360;
    const period = 0;

    beforeEach(async () => {
        pool = await StakingPool.new(
            miner,
            minerContactInfo,
            minerFeeBp,
            feeBp,
            feeCollector,
            minStakes,
            maxStakers,
            startTime,
            period
        );
    });

    it('should deploy correctly', async () => {
        assert.notEqual(pool.address, `0x${'0'.repeat(40)}`);
    });

    it('should work with minStakes correctly', async () => {
        const min = await pool.minStakes();
        assert.equal(min, toWei(1));

        await pool.sendTransaction(txGen(accounts[0], toWei(0.1)))
            .should.be.rejectedWith(revertError);

        await pool.sendTransaction(txGen(accounts[0], toWei(1)));
        const stakerInfo = await pool.stakerInfo(accounts[0]);
        assert.equal(stakerInfo[0], toWei(1));
    });

    it('should handle adding stakes properly', async () => {
        await pool.sendTransaction(txGen(accounts[0], toWei(42)));
        const minerReward = await pool.getPayout(accounts[0]);
        assert.equal(minerReward, 0);
        let poolSize = await pool.poolSize();
        assert.equal(poolSize, 1);
        const staker = await pool.stakers(0);
        assert.equal(staker, accounts[0]);
        const stakerInfo = await pool.stakerInfo(accounts[0]);
        assert.equal(stakerInfo[0], toWei(42));
        assert.equal(stakerInfo[1], 0);
        let totalStakes = await pool.totalStakes();
        assert.equal(totalStakes, toWei(42));

        await pool.sendTransaction(txGen(accounts[1], toWei(100)));
        poolSize = await pool.poolSize();
        assert.equal(poolSize, 2);
        totalStakes = await pool.totalStakes();
        assert.equal(totalStakes, toWei(142));
    });

    it('should handle withdrawing stakes properly', async () => {
        await pool.sendTransaction(txGen(accounts[0], toWei(42)));
        await pool.withdraw();
        let totalStakes = await pool.totalStakes();
        assert.equal(totalStakes, toWei(0));
        let poolBalance = await web3.eth.getBalance(pool.address);
        assert.equal(poolBalance, toWei(0));
        await pool.withdraw()
            .should.be.rejectedWith(revertError);
        // Withdraw all.
        const poolSize = await pool.poolSize();
        assert.equal(poolSize, 0);
    });

    it('should calculate dividends correctly', async () => {
        await pool.sendTransaction(txGen(accounts[0], toWei(42)));
        await forceSend(pool.address, toWei(8), treasury);
        let poolBalance = await web3.eth.getBalance(pool.address);
        assert.equal(poolBalance, toWei(50));
        // State has not been updated.
        let minerReward = await pool.getMinerFee();
        assert.equal(minerReward, 4);
        const stakerInfo = await pool.stakerInfo(accounts[0]);
        let stakes = stakerInfo[0];
        assert.equal(stakes, toWei(42));
        stakes = await pool.getPayout(accounts[0]);
        assert.equal(stakes, toWei(42 + (8 / 2)));
        await pool.withdraw();
        // Pool balance should update.
        poolBalance = await web3.eth.getBalance(pool.address);
        assert.equal(poolBalance, toWei(4));
        // Miner can withdraw as well.
        await pool.withdrawMinerFee({ from: miner });
        poolBalance = await web3.eth.getBalance(pool.address);
        assert.equal(poolBalance, 0);
        minerReward = await pool.getMinerFee();
        assert.equal(minerReward, 0);
    });

    it('should handle maintainer fee correctly', async () => {
        // Start a new pool where the pool takes 12.5% while the miner takes 50%.
        // eslint-disable-next-line max-len
        pool = await StakingPool.new(
            miner,
            minerContactInfo,
            minerFeeBp,
            1250,
            feeCollector,
            minStakes,
            maxStakers,
            startTime,
            period
        );
        await pool.sendTransaction(txGen(accounts[0], toWei(1)));
        await forceSend(pool.address, toWei(8), treasury);
        assert.equal((await pool.getProtocolFee()), toWei(1));
        assert.equal((await pool.getMinerFee()), toWei(4));
        await pool.withdrawMinerFee({ from: miner, gasPrice: 0 });
        assert.equal((await pool.getProtocolFee()), toWei(0));
        assert.equal((await pool.getMinerFee()), 0);
        const maintainerBalance = await web3.eth.getBalance(feeCollector);
        assert.equal(maintainerBalance, toWei(8 / 8));
    });

    it('should handle maturity time correctly', async () => {
        await pool.sendTransaction(txGen(accounts[0], toWei(42)));
        await forceSend(pool.address, toWei(8), treasury);
        let minerReward = await pool.getMinerFee();
        assert.equal(minerReward, toWei(4));

        // After ten years.
        await snapshotEVM();
        await addDaysOnEVM(11);
        await forceSend(pool.address, toWei(8), treasury);
        // State has not been updated.
        minerReward = await pool.getMinerFee();
        assert.equal(minerReward, toWei(0));
        let stakerReward = await pool.getPayout(accounts[0]);
        assert.equal(stakerReward, toWei(58));
        await revertEVM();
    });
});
