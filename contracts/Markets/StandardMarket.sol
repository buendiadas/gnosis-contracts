pragma solidity ^0.4.15;
import "../Markets/Market.sol";
import "../Tokens/Token.sol";
import "../Events/Event.sol";
import "../MarketMakers/MarketMaker.sol";


contract StandardMarketData {
    /*
     *  Constants
     */
    uint24 public constant FEE_RANGE = 1000000; // 100%
}

contract StandardMarketProxy is Proxy, MarketData, StandardMarketData {
    function StandardMarketProxy(address proxy, address _creator, Event _eventContract, MarketMaker _marketMaker, uint24 _fee)
        Proxy(proxy)
        public
    {
        // Validate inputs
        require(address(_eventContract) != 0 && address(_marketMaker) != 0 && _fee < FEE_RANGE);
        creator = _creator;
        createdAtBlock = block.number;
        eventContract = _eventContract;
        netOutcomeTokensSold = new int[](eventContract.getOutcomeCount());
        fee = _fee;
        marketMaker = _marketMaker;
        stage = Stages.MarketCreated;
    }
}

/// @title Standard market contract - Backed implementation of standard markets
/// @author Stefan George - <stefan@gnosis.pm>
contract StandardMarket is Proxied, Market, StandardMarketData {
    using Math for *;

    /*
     *  Modifiers
     */
    modifier isCreator() {
        // Only creator is allowed to proceed
        require(msg.sender == creator);
        _;
    }

    modifier atStage(Stages _stage) {
        // Contract has to be in given stage
        require(stage == _stage);
        _;
    }

    /*
     *  Public functions
     */
    /// @dev Allows to fund the market with collateral tokens converting them into outcome tokens
    /// @param _funding Funding amount
    function fund(uint _funding)
        public
        isCreator
        atStage(Stages.MarketCreated)
    {
        // Request collateral tokens and allow event contract to transfer them to buy all outcomes
        require(   eventContract.collateralToken().transferFrom(msg.sender, this, _funding)
                && eventContract.collateralToken().approve(eventContract, _funding));
        eventContract.buyAllOutcomes(_funding);
        funding = _funding;
        stage = Stages.MarketFunded;
        MarketFunding(funding);
    }

    /// @dev Allows market creator to close the markets by transferring all remaining outcome tokens to the creator
    function close()
        public
        isCreator
        atStage(Stages.MarketFunded)
    {
        uint8 outcomeCount = eventContract.getOutcomeCount();
        for (uint8 i = 0; i < outcomeCount; i++)
            require(eventContract.outcomeTokens(i).transfer(creator, eventContract.outcomeTokens(i).balanceOf(this)));
        stage = Stages.MarketClosed;
        MarketClosing();
    }

    /// @dev Allows market creator to withdraw fees generated by trades
    /// @return Fee amount
    function withdrawFees()
        public
        isCreator
        returns (uint fees)
    {
        fees = eventContract.collateralToken().balanceOf(this);
        // Transfer fees
        require(eventContract.collateralToken().transfer(creator, fees));
        FeeWithdrawal(fees);
    }

    /// @dev Allows to trade outcome tokens and collateral with the market maker
    /// @param outcomeTokenAmounts Amounts of each outcome token to buy or sell. If positive, will buy this amount of outcome token from the market. If negative, will sell this amount back to the market instead.
    /// @param collateralLimit If positive, this is the limit for the amount of collateral tokens which will be sent to the market to conduct the trade. If negative, this is the minimum amount of collateral tokens which will be received from the market for the trade. If zero, there is no limit.
    /// @return If positive, the amount of collateral sent to the market. If negative, the amount of collateral received from the market. If zero, no collateral was sent or received.
    function trade(int[] outcomeTokenAmounts, int collateralLimit)
        public
        atStage(Stages.MarketFunded)
        returns (int netCost)
    {
        uint8 outcomeCount = eventContract.getOutcomeCount();
        require(outcomeTokenAmounts.length == outcomeCount);

        // Calculate net cost for executing trade
        int outcomeTokenNetCost = marketMaker.calcNetCost(this, outcomeTokenAmounts);
        int fees;
        if(outcomeTokenNetCost < 0)
            fees = int(calcMarketFee(uint(-outcomeTokenNetCost)));
        else
            fees = int(calcMarketFee(uint(outcomeTokenNetCost)));

        require(fees >= 0);
        netCost = outcomeTokenNetCost.add(fees);

        require(
            (collateralLimit != 0 && netCost <= collateralLimit) ||
            collateralLimit == 0
        );

        if(outcomeTokenNetCost > 0) {
            require(
                eventContract.collateralToken().transferFrom(msg.sender, this, uint(netCost)) &&
                eventContract.collateralToken().approve(eventContract, uint(outcomeTokenNetCost))
            );

            eventContract.buyAllOutcomes(uint(outcomeTokenNetCost));
        }

        for (uint8 i = 0; i < outcomeCount; i++) {
            if(outcomeTokenAmounts[i] != 0) {
                if(outcomeTokenAmounts[i] < 0) {
                    require(eventContract.outcomeTokens(i).transferFrom(msg.sender, this, uint(-outcomeTokenAmounts[i])));
                } else {
                    require(eventContract.outcomeTokens(i).transfer(msg.sender, uint(outcomeTokenAmounts[i])));
                }

                netOutcomeTokensSold[i] = netOutcomeTokensSold[i].add(outcomeTokenAmounts[i]);
            }
        }

        if(outcomeTokenNetCost < 0) {
            // This is safe since
            // 0x8000000000000000000000000000000000000000000000000000000000000000 ==
            // uint(-int(-0x8000000000000000000000000000000000000000000000000000000000000000))
            eventContract.sellAllOutcomes(uint(-outcomeTokenNetCost));
            if(netCost < 0) {
                require(eventContract.collateralToken().transfer(msg.sender, uint(-netCost)));
            }
        }

        OutcomeTokenTrade(msg.sender, outcomeTokenAmounts, outcomeTokenNetCost, uint(fees));
    }

    /// @dev Calculates fee to be paid to market maker
    /// @param outcomeTokenCost Cost for buying outcome tokens
    /// @return Fee for trade
    function calcMarketFee(uint outcomeTokenCost)
        public
        view
        returns (uint)
    {
        return outcomeTokenCost * fee / FEE_RANGE;
    }
}
