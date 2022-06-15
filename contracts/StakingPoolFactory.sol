pragma solidity >0.4.99 <0.6.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./StakingPool.sol";


contract StakingPoolFactory is Ownable {

    using SafeMath for uint256;

    address payable public feeCollector;
    uint256 public feeBp;
    mapping(address => address[]) public userPools;
    address[] public allPools;

    event PoolCreated(address indexed miner, address pool, uint256 minerFeeBp, uint256 startTime);

    constructor(
        address payable _feeCollector,
        uint256 _feeBp
    )
        public
    {
        feeCollector = _feeCollector;
        feeBp = _feeBp;
    }

    function getUserPools() external view returns (address[] memory) {
        return userPools[msg.sender];
    }

    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    function userPoolsLength() external view returns (uint256) {
        return userPools[msg.sender].length;
    }

    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function createPool(
        string calldata minerContact,
        uint256 minerFeeBp,
        uint256 minStakes,
        uint256 maxStakers,
        uint256 startTime,
        uint8 period
    )
        external
        returns (address pool)
    {
        pool = address(new StakingPool(
            msg.sender,
            minerContact,
            minerFeeBp,
            feeBp,
            feeCollector,
            minStakes,
            maxStakers,
            startTime,
            period
        ));
        userPools[msg.sender].push(pool);
        allPools.push(pool);

        emit PoolCreated(msg.sender, pool, minerFeeBp, startTime);
    }

    function setFeeCollector(address payable _feeCollector)
        external
        onlyOwner
    {
        feeCollector = _feeCollector;
    }

    function setFeeBp(uint256 _feeBp)
        external
        onlyOwner
    {
        feeBp = _feeBp;
    }
}
