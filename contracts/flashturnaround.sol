pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

interface ERC20 {
    function totalSupply() external view returns (uint supply);
    function balanceOf(address _owner) external view returns (uint balance);
    function transfer(address _to, uint _value) external returns (bool success);
    function transferFrom(address _from, address _to, uint _value) external returns (bool success);
    function approve(address _spender, uint _value) external returns (bool success);
    function allowance(address _owner, address _spender) external view returns (uint remaining);
    function decimals() external view returns(uint digits);
    event Approval(address indexed _owner, address indexed _spender, uint _value);
}

interface SimpleNetworkInterface { //Kyber on Ropsten 0x818E6FECD516Ecc3849DAf6845e3EC868087B755
    function swapTokenToToken(ERC20 src, uint srcAmount, ERC20 dest, uint minConversionRate) external returns(uint);
    function swapEtherToToken(ERC20 token, uint minConversionRate) external payable returns(uint);
    function swapTokenToEther(ERC20 token, uint srcAmount, uint minConversionRate) external returns(uint);
}

interface UniswapFactoryInterface {
    function getExchange(address token) external view returns (address exchange);
}
interface UniswapExchangeInterface {
    function ethToTokenSwapInput(uint256 min_tokens, uint256 deadline) external payable returns (uint256  tokens_bought);
    function tokenToEthSwapInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline) external returns (uint256  eth_bought);
    function tokenToTokenSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address token_addr) external returns (uint256  tokens_bought);
}
interface IUniswapV2Router01 { //Uniswap V2 on Ropsten 0xf164fC0Ec4E93095b804a4795bBe1e041497b92a
    function WETH() external pure returns (address);
    function swapExactTokensForTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline) external payable returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
}
interface aaveLinks {
    function getLendingPool() external view returns (address); // ILendingPoolAddressesProvider
    function getLendingPoolCore() external view returns (address payable); // ILendingPoolAddressesProvider
    function addressesProvider () external view returns ( address ); // ILendingPool
    function flashLoan(address _receiver, address _reserve, uint256 _amount, bytes calldata _params) external; // ILendingPool
}

contract flashTurnaround {

    // Addresses of all relevant exchanges
    address ETH=0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // as used by Aave
    address aaveAddr=0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728; // hub to get further addresses from Aave Addresses Provider
    address kyberSC=0x818E6FECD516Ecc3849DAf6845e3EC868087B755;
    address uniswapV1factory=0x9c83dCE8CA20E9aAF9D3efc003b2ea62aBC08351;  // Factory address - Mainnet: 0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95  
    address uniswapV2router=0xf164fC0Ec4E93095b804a4795bBe1e041497b92a;

    fallback() external payable {}
    receive() external payable {}

    constructor () public payable {}

    function turnaround(address[] memory tokenPath, string[] memory exchangePath, uint injectedAmount, uint tradeAmount) public payable {
        require(tradeAmount>0 && tradeAmount>=injectedAmount); // amounts should be >0
        ERC20 baseToken=ERC20(tokenPath[0]);

        // injectedAmount : Amount to be sent to the smart contract to perform trades
        if(tokenPath[0]!=ETH) {
            if(injectedAmount>0) baseToken.transferFrom(msg.sender, address(this), injectedAmount);
            baseToken.approve(address(this), tradeAmount);
        }

        // Encode input parameters
        bytes memory params = abi.encode(tokenPath, exchangePath, injectedAmount, tradeAmount);

        // tradeAmount : Wanted amount to perform the trade. 0x9E5C7835E4b13368fd628196C4f1c6cEc89673Fa
        if(tradeAmount>injectedAmount) { // If tradeAmount is higher, than a flashloan will fill the gap
            require(tokenPath[0]==tokenPath[tokenPath.length-1]); // but for this first and last token must be the same
            aaveLinks(aaveLinks(aaveAddr).getLendingPool()).flashLoan(address(this), tokenPath[0], tradeAmount - injectedAmount, params);
        } else
            performSwaps(params, 0);
    }

    // Receiver for Aave flash loan
    function executeOperation(address _reserve, uint256 _amount, uint256 _fee, bytes calldata _params) external {
        performSwaps(_params, _fee);

        // Return flash loan
        address corePool = aaveLinks(aaveAddr).getLendingPoolCore(); //0x4295Ee704716950A4dE7438086d6f0FBC0BA9472
        if(_reserve!=ETH)
            ERC20(_reserve).transfer(corePool, _amount + _fee);
        else
            payable(corePool).transfer(_amount + _fee);
    }

    function performSwaps(bytes memory params, uint fee) private {
        address[] memory tokenPath; string[] memory exchangePath; uint injectedAmount; uint tradeAmount; uint xAmount=tradeAmount;
        (tokenPath, exchangePath, injectedAmount, tradeAmount) = abi.decode(params, (address[], string[], uint, uint));

        address targetAddr=tokenPath[0]; // changes along the tokenPath
        for (uint i=0; i<tokenPath.length-1; i++) {
            address fromAddr=tokenPath[i]; targetAddr=tokenPath[i+1];
            if (hashi(exchangePath[i])==hashi("kyberswap")) xAmount = kyberSwap(fromAddr, targetAddr, xAmount);
            if (hashi(exchangePath[i])==hashi("uniswapv1")) xAmount = uniswapv1(fromAddr, targetAddr, xAmount);
            if (hashi(exchangePath[i])==hashi("uniswapv2")) xAmount = uniswapv2(fromAddr, targetAddr, xAmount);
        }

        // If flashloan has been taken, reduce returned amount by flashloan amount
        if(tradeAmount>injectedAmount) xAmount=xAmount-(tradeAmount-injectedAmount);
        // Return remaining Tokens to sender (minus fee / margin share)
        if(targetAddr!=ETH) ERC20(targetAddr).transfer(msg.sender, xAmount-fee);
        else msg.sender.transfer(xAmount-fee);
    }

    function kyberSwap(address fromAddr, address targetAddr, uint amount) public payable returns (uint exchangedAmount) {
        SimpleNetworkInterface k = SimpleNetworkInterface(kyberSC);
        if(fromAddr!=ETH) {
            ERC20(fromAddr).approve(kyberSC, amount);
            if(targetAddr!=ETH)
                return k.swapTokenToToken(ERC20(fromAddr), amount, ERC20(targetAddr), 0);
            else
                return k.swapTokenToEther(ERC20(fromAddr), amount, 0);
        } else
            return k.swapEtherToToken{value:amount}(ERC20(targetAddr), 0);
    }

    function uniswapv1(address fromAddr, address targetAddr, uint amount) public payable returns (uint exchangedAmount) {
        UniswapFactoryInterface Factory=UniswapFactoryInterface(uniswapV1factory);      
        if(fromAddr!=ETH) {
            address exchange=Factory.getExchange(fromAddr);
            ERC20(fromAddr).approve(exchange, amount);
            UniswapExchangeInterface trade=UniswapExchangeInterface(exchange);
            if(targetAddr!=ETH)
                return trade.tokenToTokenSwapInput(amount, 1, 0, now+120, targetAddr);
            else
                return trade.tokenToEthSwapInput(amount, 1, now+120); // min eth = 0
        } else {
            address exchange=Factory.getExchange(targetAddr);
            UniswapExchangeInterface trade=UniswapExchangeInterface(exchange);
            return trade.ethToTokenSwapInput{value:amount}(1, now+120); //min tokens = 0
        }
    }

    function addr(address a1, address a2) private pure returns (address[] memory) {
        address[] memory a = new address[](2); a[0]=a1; a[1]=a2;
        return a;
    }
    function uniswapv2(address fromAddr, address targetAddr, uint amount) public payable returns (uint exchangedAmount) {
        IUniswapV2Router01 u=IUniswapV2Router01(uniswapV2router);
        address WETH=u.WETH();
        if(fromAddr!=ETH) {
            ERC20(fromAddr).approve(uniswapV2router, amount);
            if(targetAddr!=ETH)
                return u.swapExactTokensForTokens(amount, 0, addr(fromAddr, targetAddr), address(this), now+120)[1];
            else
                return u.swapExactTokensForETH(amount, 0, addr(fromAddr, WETH), address(this), now+120)[1];
        } else
            return u.swapExactETHForTokens{value:amount}(0, addr(WETH, targetAddr), address(this), now+120)[1];
    }

    function hashi(string memory text) private pure returns (bytes32 hash) {
        return keccak256(abi.encodePacked(text));
    }

    function getEthBalance() public view returns (uint) {
        return address(this).balance;
    }
    function getTokenBalance(address tokenAddress) public view returns (uint) {
        return ERC20(tokenAddress).balanceOf(address(this));
    }
}
