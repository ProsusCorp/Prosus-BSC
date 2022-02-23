
pragma solidity ^0.8.0;


interface interfaz_BEP20 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}


abstract contract contexto {

    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

}


contract Prosus_BSC is contexto, interfaz_BEP20 {
    
    address payable private deployer;
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 internal _totalSupply;

    constructor() {
        _name = "Prosus-BSC";
        _symbol = "bPROSUS";
        _decimals = 12;
        _totalSupply = 0;
        _balances[msg.sender] = _totalSupply;

        deployer = payable(msg.sender);
 
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    /*=================================
    =          MODIFICADORES          =
    =================================*/
    // sólo quienes tienen tokens
    modifier conTokens() {
        require(myTokens() > 0);
        _;
    }
    
    // sólo quienes tienen ganancias
    modifier conGanancias() {
        require(myDividends(true) > 0);
        _;
    }
    
    modifier onlyOwner() {
        require(msg.sender == deployer, "No eres el creador del contrato");
        _;
    }
    
    /*==============================
    =           EVENTOS            =
    ==============================*/
    event onTokenPurchase(address indexed customerAddress, uint256 incomingBNB, uint256 tokensMinted, address indexed referredBy);
    event onTokenSell(address indexed customerAddress, uint256 tokensBurned, uint256 bnbEarned);
    event onReinvestment(address indexed customerAddress, uint256 bnbReinvested, uint256 tokensMinted);
    event onWithdraw(address indexed customerAddress, uint256 bnbWithdrawn);
    
    /*=====================================
    =            CONFIGURABLES            =
    =====================================*/
    uint8 constant internal dividendFee_ = 10;  // 10%   ( dividendFee_ / 100  =  porcentaje )
    uint256 constant internal tokenPriceInitial_     = 0.00000100       * (10**18); // precio en BNB
    uint256 constant internal tokenPriceIncremental_ = 0.00000001       * (10**18); 
    uint256 constant internal magnitude = 2**64;
    
   /*================================
    =            DATASETS         	=
    ===============================*/
    // cantidad de cripto-activos para cada dirección (número escalado)
    mapping(address => uint256) internal tokenBalanceLedger_;
    mapping(address => uint256) internal referralBalance_;
    mapping(address => int256) internal payoutsTo_;
    
    // otras métricas
    mapping(address => bool) internal activatedPlayer_;
    
    mapping(address => uint256) internal referralsOf_;
    mapping(address => uint256) internal referralEarningsOf_;
    
    uint256 internal players;
    uint256 internal AMMsupply_ = 0;
    uint256 internal profitPerShare_;
    
    /*=======================================
    =            FUNCIONES PÜBLICAS         =
    =======================================*/
    // Convierte todos los BNB entrantes en Prosus_AMM, para cada usuario. Y agrega un complemento para referidos (si corresponde).
    function buy(address _referredBy) external payable {
        
        // Depositar BNB en el contrato; crear los tokens.
        purchaseTokens(msg.value, _referredBy);
        
		// Si en los depósitos 'msgSender = 0' , significa que es el primer depósito.
        // Por esto, se agrega 1 al recuento total de participantes y al contador de sus referidos.
        if (activatedPlayer_[msg.sender] == false) {
            activatedPlayer_[msg.sender] = true;
            players += 1;
            referralsOf_[_referredBy] += 1;
        }
    }
    
    // Función de respaldo para manejar BNB enviados directamente al contrato: "deployer" es el referido.
    receive() payable external {
        purchaseTokens(msg.value, deployer);
    }
    
    // Convertir los dividendos en Prosus_AMM.
    function reinvest() conGanancias() public {
        // obtener dividendos
        uint256 _dividends = myDividends(false); // recuperar bono de referidos (ver el código a continuación)
        
        // pagar (virtualmente) dividendos
        address _customerAddress = msg.sender;
        payoutsTo_[_customerAddress] +=  (int256) (_dividends * magnitude);

        // recuperar bono de referidos
        _dividends += referralBalance_[_customerAddress];
        referralBalance_[_customerAddress] = 0;
        
        // ejecutar una orden de compra "virtual", usando el retiro de dividendos.
        uint256 _tokens = purchaseTokens(_dividends, deployer);
        
        // emitir evento
        emit onReinvestment(_customerAddress, _dividends, _tokens);
    }
    
    // Alias para vender y girar.
    function exit() public {
        // Obtener el recuento de tokens para la persona que lo solicita y venderlos todos.
        address _customerAddress = msg.sender;
        uint256 _tokens = tokenBalanceLedger_[_customerAddress];
        if(_tokens > 0) sell(_tokens);
        
		// ejecutar
        withdraw();
    }

    // Los participantes retiran sus ganancias.
    function withdraw() conGanancias() public {
        // datos de configuración
        address payable _customerAddress = payable(msg.sender);
        uint256 _dividends = myDividends(false); // tomar bono de referidos (más adelante en el código)
        
        // actualizar el trazador de dividendos
        payoutsTo_[_customerAddress] +=  (int256) (_dividends * magnitude);
        
        // agregar bono de referidos
        _dividends += referralBalance_[_customerAddress];
        referralBalance_[_customerAddress] = 0;
        
        // ejecutar
        _customerAddress.transfer(_dividends);
        
        // emitir evento
        emit onWithdraw(_customerAddress, _dividends);
    }
    
    // liquidar Prosus_AMM (convertirlos a BNB)
    function sell(uint256 _amountOfTokens) conTokens() public {
        // datos de configuración
        address _customerAddress = msg.sender;
        require(_amountOfTokens <= tokenBalanceLedger_[_customerAddress]); // comprobar saldo
        uint256 _tokens = _amountOfTokens;
        uint256 _bnb = tokensToBNB_(_tokens);
        uint256 _dividends = _bnb / dividendFee_;
        uint256 _taxedBNB = _bnb - _dividends;
        
        // quemar los tokens vendidos
        AMMsupply_ = AMMsupply_ - _tokens;
        tokenBalanceLedger_[_customerAddress] = tokenBalanceLedger_[_customerAddress] - _tokens;
        
        // actualizar el trazador de dividendos
        int256 _updatedPayouts = (int256) (profitPerShare_ * _tokens + (_taxedBNB * magnitude));
        payoutsTo_[_customerAddress] -= _updatedPayouts;       
        
        if (AMMsupply_ > 0) {         // para evitar dividir por cero
            // actualizar la cantidad de dividendos por cada token
            profitPerShare_ = profitPerShare_ + (_dividends * magnitude) / AMMsupply_ ;
        }
        
        // emitir evento
        emit onTokenSell(_customerAddress, _tokens, _taxedBNB);
    }

    /*----------  AUXILIARES ("helpers") Y CÁLCULOS  ----------*/
    
    // Buscar si el enlace de referido ya está siendo usado.
    function playerStatus(address _player) public view returns (bool) {
        return activatedPlayer_[_player];
    }
    
    function myTotalReferrals() public view returns (uint) {
        return referralsOf_[msg.sender];
    }
    
    function myTotalReferralEarnings() public view returns (uint) {
        return referralEarningsOf_[msg.sender];
    }
    
    // ----------
    
    function totalReferralsOf(address _user) public view returns (uint) {
        return referralsOf_[_user];
    }
    
    function totalReferralEarningsOf(address _user) public view returns (uint) {
        return referralEarningsOf_[_user];
    }
    
    // ----------
    
    // Método para ver los BNB vigentes, almacenados en el contrato.
    function totalBNBBalance() public view returns(uint) {
        return address(this).balance;
    }
    
    // Obtener cantidad total ("suministro") de Prosus_AMM.
    function AMM_totalSupply() public view returns(uint256) {
        return AMMsupply_;
    }
    
    // Obtener cantidad de Prosus_AMM que posee el usuario.
    function myTokens() public view returns(uint256) {
        address _customerAddress = msg.sender;
        return AMM_balanceOf(_customerAddress);
    }

    // Recuperar los dividendos pertenecientes a la persona que lo solicita.    
    /* Si `_includeReferralBonus` es 1 (verdadero), el bono de referidos se incluirá en los cálculos.
     * La razón de esto es que, en la interfaz, deben aparecer los dividendos totales (global + referidos)
     * pero en los cálculos internos los queremos por separado. */ 
    function myDividends(bool _includeReferralBonus) public view returns(uint256) {
        address _customerAddress = msg.sender;
        return dividendsOf(_customerAddress,_includeReferralBonus);
    }
    
    // Recuperar el balance de Prosus_AMM, de una determinada dirección.
    function AMM_balanceOf(address _customerAddress) view public returns(uint256) {
        return tokenBalanceLedger_[_customerAddress];
    }
    
    // Recuperar el balance de los dividendos, de una sola dirección.
    function dividendsOf(address _customerAddress,bool _includeReferralBonus) view public returns(uint256) {
        uint256 regularDividends = (uint256) ((int256)(profitPerShare_ * tokenBalanceLedger_[_customerAddress]) - payoutsTo_[_customerAddress]) / magnitude;
        if (_includeReferralBonus){
            return regularDividends + referralBalance_[_customerAddress];
        } else {
            return regularDividends;
        }
    }
    
    // Obtener el precio de compra de un solo token.
    function sellPrice() public view returns(uint256) {
        if(AMMsupply_ == 0){  // se necesita un valor para calcular el suministro.
            return tokenPriceInitial_ - tokenPriceIncremental_;
        } else {
            uint256 _bnb = tokensToBNB_(1e12);
            uint256 _dividends = _bnb / dividendFee_;
            uint256 _taxedBNB = _bnb - _dividends;
            return _taxedBNB;
        }
    }
    
    // Obtener el precio de venta de un solo token.
    function buyPrice() public view returns(uint256) {
        if(AMMsupply_ == 0){  // se necesita un valor para calcular el suministro de tokens.
            return tokenPriceInitial_ + tokenPriceIncremental_;
        } else {
            uint256 _bnb = tokensToBNB_(1e12);
            uint256 _dividends = _bnb / dividendFee_;
            uint256 _taxedBNB = _bnb + _dividends;
            return _taxedBNB;
        }
    }
    
    // Función para que la interfaz recupere dinámicamente la escala de precios de las órdenes de compra.
    function calculateTokensReceived(uint256 _bnbToSpend) public view returns(uint256) {
        uint256 _dividends = _bnbToSpend / dividendFee_;
        uint256 _taxedBNB = _bnbToSpend - _dividends;
        uint256 _amountOfTokens = bnbToTokens_(_taxedBNB);
        
        return _amountOfTokens;
    }
    
    // Función de la interfaz para recuperar dinámicamente la escala de precios de las órdenes de venta.
    function calculateBNBReceived(uint256 _tokensToSell) public view returns(uint256) {
        require(_tokensToSell <= AMMsupply_);
        uint256 _bnb = tokensToBNB_(_tokensToSell);
            uint256 _dividends = _bnb / dividendFee_;
            uint256 _taxedBNB = _bnb - _dividends;
        return _taxedBNB;
    }
    
    
    /*==========================================
    =            FUNCIONES INTERNAS            =
    ==========================================*/
    function purchaseTokens(uint256 _incomingBNB, address _referredBy) internal returns(uint256) {
        // datos de configuración
        address _customerAddress = msg.sender;
        uint256 _undividedDividends = _incomingBNB / dividendFee_;
        uint256 _taxedBNB = _incomingBNB - _undividedDividends;
        uint256 _amountOfTokens = bnbToTokens_(_taxedBNB);

        uint256 _referralBonus = _undividedDividends / 2 ;
        uint256 _dividends = _undividedDividends - _referralBonus;
        uint256 _fee = _dividends * magnitude;
 
        require(_amountOfTokens > 0 && (_amountOfTokens + AMMsupply_) > AMMsupply_) ; // prevenir saturación
        
        if ( _referredBy != 0x0000000000000000000000000000000000000000 ) { // usan enlace de referidos
            // distribución de los bonos por referido
            referralBalance_[_referredBy] = referralBalance_[_referredBy] + _referralBonus ;
        } else { // no usan enlace de referidos
            // se devuelve bono de referidos al reparto global de dividendos.
            _dividends = _dividends + _referralBonus;
            _fee = _dividends * magnitude;
        }
        
        if(AMMsupply_ > 0){  // Para no entregar BNB infinito a los usuarios.
            // agregar tokens al suministo
            AMMsupply_ = AMMsupply_ + _amountOfTokens;
 
            // tomar la cantidad de dividendos obtenidos a través de esta transacción y distribuirlos a los participantes
            profitPerShare_ += (_dividends * magnitude / AMMsupply_ );
            
            // calcular la cantidad de tokens que recibe el usuario cuando compra
            _fee = _fee - (_fee - (_amountOfTokens * ( _dividends * magnitude / (AMMsupply_) )));
        
         } else {
            // agregar tokens al suministro
            AMMsupply_ = _amountOfTokens;
         }
        
        // actualizar el suministro circulante usando los balances de usuario
        tokenBalanceLedger_[_customerAddress] = tokenBalanceLedger_[_customerAddress] + _amountOfTokens;
        
		// actualizar trazador de dividendos antes de entregar dividendos
        int256 _updatedPayouts = int256( (int256(profitPerShare_) * int256(_amountOfTokens)) - int256(_fee) ); // sólo cantidades enteras
        payoutsTo_[_customerAddress] += _updatedPayouts;

        referralEarningsOf_[_referredBy] += (_referralBonus);
        
        // emitir evento
        emit onTokenPurchase(_customerAddress, _incomingBNB, _amountOfTokens, _referredBy);

        return _amountOfTokens;        
    }

    // Calcular el precio de Prosus_AMM en función de la cantidad de BNB entrantes.
	// Se realizan algunas conversiones para evitar errores decimales o desbordamientos en el código Solidity.
    function bnbToTokens_(uint256 _bnb) internal view returns(uint256) {
        uint256 _tokenPriceInitial = tokenPriceInitial_ * 1e12;
        uint256 _tokensReceived = 
         (
            (
                (
                    (sqrt
                        (
                            (_tokenPriceInitial**2)
                            +
                            (2*(tokenPriceIncremental_ * 1e12)*(_bnb * 1e12))
                            +
                            (((tokenPriceIncremental_)**2)*(AMMsupply_**2))
                            +
                            (2*(tokenPriceIncremental_)*_tokenPriceInitial*AMMsupply_)
                        )
                    ) - _tokenPriceInitial
                )
            ) / (tokenPriceIncremental_)
        ) - (AMMsupply_) ;
  
        return _tokensReceived;
    }
        function sqrt(uint x) internal pure returns (uint y) {
            uint z = (x + 1) / 2;
            y = x;
            while (z < y) {
                y = z;
                z = (x / z + z) / 2;
            }
        }
    
    // Calcular el precio de venta de Prosus_AMM.
	// Se realizan algunas conversiones para evitar errores decimales o desbordamientos en el código Solidity.
     function tokensToBNB_(uint256 amount) internal view returns(uint256) {
        uint256 _tokens = (amount + 1e12);
        uint256 _AMMsupply = (AMMsupply_ + 1e12)/1e12;
        uint256 _BNBrecibido =  
        (
            (
                (
                    (
                        (
                        tokenPriceInitial_ + (tokenPriceIncremental_ * _AMMsupply)
                        ) - tokenPriceIncremental_
                    ) * (_tokens - 1e12)
                ) - (tokenPriceIncremental_ * ((_tokens**2 - _tokens)/1e12))/2
            ) / 1e12 
        );

        return _BNBrecibido;
    }

    /*==========================================
    =        INTERACCION AMM / BEP20           =
    ==========================================*/
    function AMM_BEP (uint256 _amountOfTokens) public returns(bool){  // traspasar saldo de cuenta Prosus_AMM a cuenta Prosus_BEP
        // asegurar que tengamos los tokens_AMM solicitados
        require(_amountOfTokens <= tokenBalanceLedger_[msg.sender]);

        // quemar tokens_AMM
        AMMsupply_ = AMMsupply_ - _amountOfTokens;
        tokenBalanceLedger_[msg.sender] = tokenBalanceLedger_[msg.sender] - _amountOfTokens;
            
        // actualizar (disminuir) el trazador de dividendos
        payoutsTo_[msg.sender] -= (int256) (profitPerShare_ * _amountOfTokens);

        // minar tokens_BEP
        _mint(msg.sender, _amountOfTokens);    

        return true ;
    }

    function BEP_AMM (uint256 _amountOfTokens) public returns(bool){  // traspasar saldo de cuenta Prosus_BEP a cuenta Prosus_AMM
        // asegurar que tengamos los tokens_BEP solicitados
        require(_amountOfTokens <= _balances[msg.sender]);

        // quemar tokens_BEP
        _totalSupply = _totalSupply - _amountOfTokens;
        _balances[msg.sender] = _balances[msg.sender] - _amountOfTokens;
            
        // actualizar (aumentar) el trazador de dividendos
        payoutsTo_[msg.sender] += (int256) (profitPerShare_ * _amountOfTokens);

        // minar tokens_AMM
        _mintAMM(msg.sender, _amountOfTokens);    

        return true ;
    }

    function SupplyPeg(uint256 amount) external onlyOwner returns (bool) {
       _mint(msg.sender, amount);
       return true;
    }

    function _mintAMM(address account, uint256 amount) internal {
        require(account != address(0), "BEP20: mint to the zero address?");
        AMMsupply_ = AMMsupply_ + amount ;
        tokenBalanceLedger_[account] = tokenBalanceLedger_[account] + amount ;
        emit Transfer(address(0), account, amount);
    }  


    /*==========================================
    =            FUNCIONES BEP20            =
    ==========================================*/
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, _allowances[owner][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = _allowances[owner][spender];
        require(currentAllowance >= subtractedValue, "BEP20: decreased allowance below zero");
        unchecked { _approve(owner, spender, currentAllowance - subtractedValue); }
        return true;
    }

    function burn(uint _amount) public {
        _burn(msg.sender, _amount);
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "BEP20: transfer from the zero address");
        require(to != address(0), "BEP20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "BEP20: transfer amount exceeds balance");
        unchecked { _balances[from] = fromBalance - amount; }
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "BEP20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "BEP20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "BEP20: burn amount exceeds balance");
        unchecked { _balances[account] = accountBalance - amount; }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "BEP20: insufficient allowance");
            unchecked { _approve(owner, spender, currentAllowance - amount); }
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {
    }


}


 /*================================
 =            CRÉDITOS            =
 ================================*/
 // autor: Prosus Corp (research and technological development)
 // mantenimiento: YerkoBits
 // SPDX-License-Identifier: MIT
 // open-source: Prosus-BSC está basado en varios contratos de código abierto, principalmente Hourglass, OpenZeppelin, StrongHands.
 // 

