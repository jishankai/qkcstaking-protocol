pragma solidity >0.4.99 <0.6.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";


contract StakingPool is ReentrancyGuard {

    using SafeMath for uint256;

    struct StakerInfo {
        uint256 stakes;
        uint256 arrPos;
    }
    enum Period{ ONE_WEEK, ONE_MONTH, THREE_MONTHS, ONE_YEAR }

    uint256 constant MAX_BP = 10000;

    uint256 public startTime;
    uint256 public endTime;

    uint256 public minStakes;
    uint256 public maxStakers;
    uint256 public totalStakes;
    address[] public stakers;
    mapping (address => StakerInfo) public stakerInfo;

    address public miner;
    uint256 public minerFee;
    uint256 public minerFeeBp;
    string  public minerContact;
    address payable public protocol;
    uint256 public protocolFee;
    uint256 public protocolFeeBp;

    constructor(
        address _miner,
        string  memory _minerContact,
        uint256 _minerFeeBp,
        uint256 _protocolFeeBp,
        address payable _protocol,
        uint256 _minStakes,
        uint256 _maxStakers,
        uint256 _startTime,
        uint8 _period
    )
        public
    {
        require(
            _minerFeeBp + _protocolFeeBp <= MAX_BP,
            "Fee rate should be in basis point."
        );
        require(_startTime > now, "StartTime should be later than now.");
        miner = _miner;
        protocol = _protocol;
        minerContact = _minerContact;
        minStakes = _minStakes;
        minerFeeBp = _minerFeeBp;
        protocolFeeBp = _protocolFeeBp;
        maxStakers = _maxStakers;
        startTime = _startTime;
        if (Period(_period) == Period.ONE_WEEK) {
            endTime = _startTime + 1 weeks;
        } else if (Period(_period) == Period.ONE_MONTH) {
            endTime = _startTime + 4 weeks;
        } else if (Period(_period) == Period.THREE_MONTHS) {
            endTime = _startTime + 12 weeks;
        } else {
            endTime = _startTime + 365 days;
        }
    }

    modifier onlyMiner() {
        require(msg.sender == miner, "Only miner can call this function.");
        _;
    }

    function poolSize() public view returns (uint256) {
        return stakers.length;
    }

    function () external payable {
        require(now < startTime, "Invalid staking time.");

        StakerInfo storage info = stakerInfo[msg.sender];
        if (info.stakes == 0) {
            require(msg.value >= minStakes, "Invalid stakes.");
            require(stakers.length < maxStakers, "Too many stakers.");
            info.arrPos = stakers.length;
            stakers.push(msg.sender);
        }

        info.stakes = info.stakes.add(msg.value);
        totalStakes = totalStakes.add(msg.value);
    }

    function _calculatePayout() private {
        uint256 balance = address(this).balance.sub(msg.value);
        require(balance > 0, "Balance is zero");
        uint256 dividend = _getDividend(balance);
        if (dividend == 0) {
            return;
        }
        uint256 totalPaid = 0;
        uint256 calculatedMinerFeeBp = getMinerFeeBp();
        uint256 feeBp = protocolFeeBp.add(calculatedMinerFeeBp);

        uint256 stakerPayout = dividend.mul(MAX_BP - feeBp).div(MAX_BP);
        for (uint256 i = 0; i < stakers.length; i++) {
            StakerInfo storage info = stakerInfo[stakers[i]];
            uint256 toPay = stakerPayout.mul(info.stakes).div(totalStakes);
            totalPaid = totalPaid.add(toPay);
            info.stakes = info.stakes.add(toPay);
        }
        totalStakes = totalStakes.add(totalPaid);

        uint256 totalFee = dividend.sub(totalPaid);
        // For miner
        if (calculatedMinerFeeBp > 0) {
            uint256 feeForMiner = totalFee.mul(calculatedMinerFeeBp).div(feeBp);
            minerFee = minerFee.add(feeForMiner);
            // For pool maintainer
            uint256 feeForProtocol = totalFee.sub(feeForMiner);
            protocolFee = protocolFee.add(feeForProtocol);
        } else {
            protocolFee = protocolFee.add(totalFee);
        }

        assert(balance >= totalStakes.add(minerFee).add(protocolFee));
    }

    function _getDividend(uint256 balance) private view returns (uint256) {
        uint256 recordedAmount = totalStakes.add(minerFee).add(protocolFee);
        return balance.sub(recordedAmount);
    }

    function withdraw() public nonReentrant {
        _calculatePayout();
        StakerInfo storage info = stakerInfo[msg.sender];
        require(info.stakes > 0, "Balance is not enough.");
        require(stakers[info.arrPos] == msg.sender, "No Access");

        uint256 amount = getPayout(msg.sender);
        totalStakes = totalStakes.sub(info.stakes);
        info.stakes = 0;

        msg.sender.transfer(amount);

        stakerInfo[stakers[stakers.length.sub(1)]].arrPos = info.arrPos;
        stakers[info.arrPos] = stakers[stakers.length.sub(1)];
        stakers.length = stakers.length.sub(1);
        delete stakerInfo[msg.sender];
    }

    function withdrawMinerFee() public onlyMiner nonReentrant {
        _calculatePayout();

        uint256 feeM = minerFee;
        minerFee = 0;
        msg.sender.transfer(feeM);
        uint256 feeP = protocolFee;
        protocolFee = 0;
        protocol.transfer(feeP);
    }

    function getStakes(address staker) public view returns (uint256) {
        if (totalStakes == 0) {
            return 0;
        }
        StakerInfo storage info = stakerInfo[staker];
        return info.stakes;
    }

    function getPayout(address staker) public view returns (uint256) {
        if (totalStakes == 0) {
            return 0;
        }
        uint256 dividend = _getDividend(address(this).balance);
        uint256 calculatedMinerFeeBp = getMinerFeeBp();
        uint256 feeBp = calculatedMinerFeeBp + protocolFeeBp;
        uint256 stakerPayout = dividend.mul(MAX_BP - feeBp).div(MAX_BP);
        StakerInfo storage info = stakerInfo[staker];
        uint256 toPay = stakerPayout.mul(info.stakes).div(totalStakes);
        return info.stakes.add(toPay);
    }

    function getMinerFee() public view returns (uint256) {
        uint256 calculatedMinerFeeBp = getMinerFeeBp();
        uint256 dividend = _getDividend(address(this).balance).mul(calculatedMinerFeeBp).div(stakers.length > 0 ? MAX_BP : calculatedMinerFeeBp.add(protocolFeeBp));
        return minerFee.add(dividend);
    }

    function getProtocolFee() public view returns (uint256) {
        uint256 calculatedMinerFeeBp = getMinerFeeBp();
        uint256 dividend = _getDividend(address(this).balance).mul(protocolFeeBp).div(stakers.length > 0 ? MAX_BP : calculatedMinerFeeBp.add(protocolFeeBp));
        return protocolFee.add(dividend);
    }

    function getMinerFeeBp() public view returns (uint256) {
        if (endTime + 3 days <= now) {
            return 0;
        } else if (endTime + 1 days < now) {
            return minerFeeBp.mul(now.sub(1 days)).div(3 days);
        } else {
            return minerFeeBp;
        }
    }
}
