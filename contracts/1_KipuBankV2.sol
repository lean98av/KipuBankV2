// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title KipuBankV2
 * @author lean98av
 * @notice Contrato bancario educativo: bóveda multi-token con control de acceso y oráculo Chainlink.
 * @dev Soporta ETH y ERC20s, con límites globales y por transacción. 
 */
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*////////////////////////////////////////////////////
                        ROLES
    ////////////////////////////////////////////////////*/
    bytes32 public constant ADMIN_ROLE = DEFAULT_ADMIN_ROLE;

    /*////////////////////////////////////////////////////
                        TIPOS
    ////////////////////////////////////////////////////*/
    enum TokenState { Unsupported, Supported }

    struct Account {
        uint256 balance;   /// @notice Saldo total de ETH de la cuenta
        string name;       /// @notice Nombre del titular
        string email;      /// @notice Email del titular
        bool exists;       /// @notice Indica si la cuenta fue creada
    }

    struct TokenData {
        TokenState state;  /// @notice Estado del token (soportado o no)
        uint8 decimals;    /// @notice Decimales del token
        address priceFeed; /// @notice Oráculo Chainlink para este token (USD)
    }

    /*////////////////////////////////////////////////////
                        CONSTANTES E INMUTABLES
    ////////////////////////////////////////////////////*/
    uint256 public constant USD_FEED_DECIMALS = 1e8;       // Decimales de los price feeds
    uint256 public constant MAX_WITHDRAW_AMOUNT = 0.1 ether; // Límite por retiro (ETH)
    address public constant NATIVE_TOKEN = address(0);     // Representa ETH

    uint256 public immutable i_bankCap;                     // Cap global de depósitos
    AggregatorV3Interface public immutable i_ethPriceFeed; // Oráculo ETH/USD

    /*////////////////////////////////////////////////////
                        ESTADO
    ////////////////////////////////////////////////////*/
    mapping(address => Account) private accounts;                     // usuario → Account
    mapping(address => mapping(address => uint256)) private balances; // usuario → token → balance
    mapping(address => TokenData) private tokenCatalog;               // token → TokenData

    uint256 private s_depositCounter;
    uint256 private s_withdrawCounter;
    uint256 private s_totalBankBalance;

    /*////////////////////////////////////////////////////
                        EVENTOS
    ////////////////////////////////////////////////////*/
    event Bank_Deposit(address indexed user, address indexed token, uint256 amount);
    event Bank_Withdraw(address indexed user, address indexed token, uint256 amount);
    event TokenUpdated(address indexed token, TokenState state);

    /*////////////////////////////////////////////////////
                        ERRORES
    ////////////////////////////////////////////////////*/
    /// @notice Se lanza si el usuario intenta crear una cuenta que ya existe
    error Bank_AccountAlreadyExists();

    /// @notice Se lanza si se opera con una cuenta inexistente
    error Bank_AccountNotExists();

    /// @notice Se lanza si el depósito excede el límite global
    error Bank_ExceedBankCap();

    /// @notice Se lanza si se intenta retirar más que el límite por transacción
    /// @param limit Límite máximo permitido
    /// @param requested Monto solicitado
    error Bank_ExceedWithdrawAmount(uint256 limit, uint256 requested);

    /// @notice Se lanza si los fondos disponibles son insuficientes
    /// @param available Saldo disponible
    /// @param requested Monto solicitado
    error Bank_InsufficientFunds(uint256 available, uint256 requested);

    /// @notice Se lanza cuando el depósito es inválido (ej. cero)
    error Bank_InvalidDeposit();

    /// @notice Se lanza si la transferencia de ETH falla
    error Bank_TransferError();

    /// @notice Se lanza si el token no es soportado
    error Bank_TokenNotSupported();

    /*////////////////////////////////////////////////////
                        CONSTRUCTOR
    ////////////////////////////////////////////////////*/
    /// @param ethPriceFeedAddress Dirección del oráculo ETH/USD
    /// @param bankCap Límite global del banco (USD-feed decimales)
    constructor(address ethPriceFeedAddress, uint256 bankCap) {
        _grantRole(ADMIN_ROLE, msg.sender);
        i_ethPriceFeed = AggregatorV3Interface(ethPriceFeedAddress);
        i_bankCap = bankCap;
    }

    /*////////////////////////////////////////////////////
                    GESTIÓN DE TOKENS
    ////////////////////////////////////////////////////*/
    /// @notice Agrega o actualiza un token soportado
    function setToken(
        address token,
        uint8 decimals,
        address priceFeed,
        bool supported
    ) external onlyRole(ADMIN_ROLE) {
        tokenCatalog[token] = TokenData({
            state: supported ? TokenState.Supported : TokenState.Unsupported,
            decimals: decimals,
            priceFeed: priceFeed
        });
        emit TokenUpdated(token, tokenCatalog[token].state);
    }

    /*////////////////////////////////////////////////////
                    CREAR CUENTA / DEPÓSITO
    ////////////////////////////////////////////////////*/
    /// @notice Crea cuenta nueva y opcionalmente deposita ETH
    /// @param email Email del usuario
    /// @param name Nombre del usuario
    function createAccount(string memory email, string memory name) external payable {
        if (accounts[msg.sender].exists) revert Bank_AccountAlreadyExists();
        if (s_totalBankBalance + msg.value > i_bankCap) revert Bank_ExceedBankCap();

        accounts[msg.sender] = Account({
            balance: 0,
            email: email,
            name: name,
            exists: true
        });

        if (msg.value > 0) {
            balances[msg.sender][NATIVE_TOKEN] += msg.value;
            s_totalBankBalance += msg.value;
            s_depositCounter++;
            emit Bank_Deposit(msg.sender, NATIVE_TOKEN, msg.value);
        }
    }

    /// @notice Deposita ETH en la bóveda del usuario
    function deposit() external payable {
        if (!accounts[msg.sender].exists) revert Bank_AccountNotExists();
        if (msg.value == 0) revert Bank_InvalidDeposit();
        if (s_totalBankBalance + msg.value > i_bankCap) revert Bank_ExceedBankCap();

        balances[msg.sender][NATIVE_TOKEN] += msg.value;
        s_totalBankBalance += msg.value;
        s_depositCounter++;
        emit Bank_Deposit(msg.sender, NATIVE_TOKEN, msg.value);
    }

    /// @notice Deposita tokens ERC20 soportados
    function depositToken(address token, uint256 amount) external {
        if (!accounts[msg.sender].exists) revert Bank_AccountNotExists();
        TokenData memory td = tokenCatalog[token];
        if (td.state != TokenState.Supported) revert Bank_TokenNotSupported();
        if (amount == 0) revert Bank_InvalidDeposit();

        balances[msg.sender][token] += amount;
        s_depositCounter++;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Bank_Deposit(msg.sender, token, amount);
    }

    /*////////////////////////////////////////////////////
                        RETIROS
    ////////////////////////////////////////////////////*/
    /// @notice Retira ETH respetando límite por transacción
    function withdraw(uint256 amount) external nonReentrant {
        if (!accounts[msg.sender].exists) revert Bank_AccountNotExists();
        if (amount > MAX_WITHDRAW_AMOUNT) revert Bank_ExceedWithdrawAmount(MAX_WITHDRAW_AMOUNT, amount);
        uint256 userBalance = balances[msg.sender][NATIVE_TOKEN];
        if (userBalance < amount) revert Bank_InsufficientFunds(userBalance, amount);

        balances[msg.sender][NATIVE_TOKEN] -= amount;
        s_totalBankBalance -= amount;
        s_withdrawCounter++;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert Bank_TransferError();
        emit Bank_Withdraw(msg.sender, NATIVE_TOKEN, amount);
    }

    /// @notice Retira tokens ERC20 respetando límites
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        if (!accounts[msg.sender].exists) revert Bank_AccountNotExists();
        TokenData memory td = tokenCatalog[token];
        if (td.state != TokenState.Supported) revert Bank_TokenNotSupported();
        if (amount > MAX_WITHDRAW_AMOUNT) revert Bank_ExceedWithdrawAmount(MAX_WITHDRAW_AMOUNT, amount);

        uint256 userBalance = balances[msg.sender][token];
        if (userBalance < amount) revert Bank_InsufficientFunds(userBalance, amount);

        balances[msg.sender][token] -= amount;
        s_withdrawCounter++;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Bank_Withdraw(msg.sender, token, amount);
    }

    /*////////////////////////////////////////////////////
                        UTILIDADES / VISTAS
    ////////////////////////////////////////////////////*/
    /// @notice Devuelve balance de un usuario para un token
    function getBalance(address user, address token) external view returns(uint256) {
        if (!accounts[user].exists) revert Bank_AccountNotExists();
        return balances[user][token];
    }

    /// @notice Devuelve precio ETH/USD desde Chainlink
    function getEthPriceInUsd() public view returns(uint256) {
        (, int256 price,,,) = i_ethPriceFeed.latestRoundData();
        return uint256(price);
    }

    /// @notice Convierte wei a USD usando el oráculo
    function convertWeiToUsd(uint256 weiAmount) external view returns(uint256) {
        uint256 price = getEthPriceInUsd();
        return (weiAmount * price) / 1e18;
    }

    /// @notice Devuelve el número total de depósitos realizados
    function getDepositCount() external view returns(uint256) {
        return s_depositCounter;
    }

    /// @notice Devuelve el número total de retiros realizados
    function getWithdrawCount() external view returns(uint256) {
        return s_withdrawCounter;
    }
}
