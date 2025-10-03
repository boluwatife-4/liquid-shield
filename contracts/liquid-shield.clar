;; Title: LiquidShield Protocol
;; 
;; Summary: Autonomous collateral protection system for Bitcoin-backed lending positions
;; on Stacks, featuring real-time risk monitoring, automated position reinforcement,
;; and decentralized treasury management to safeguard leveraged positions against
;; liquidation cascades.
;;
;; Description: LiquidShield is a sophisticated DeFi protocol built on Stacks that provides
;; institutional-grade protection for leveraged Bitcoin positions. The protocol continuously
;; monitors collateral health ratios and deploys intelligent capital rebalancing strategies
;; to prevent liquidations. Users deposit collateral into protected vaults that benefit from
;; autonomous reinforcement mechanisms, emergency intervention systems, and community-governed
;; treasury reserves. The protocol implements multi-layered risk stratification, predictive
;; analytics for position health, and configurable protection parameters, making it ideal for
;; Bitcoin-backed lending platforms, DeFi protocols, and institutional traders seeking to
;; minimize liquidation risk while maintaining capital efficiency on Bitcoin's Layer 2.

;; CONSTANTS - Protocol Configuration

;; Protocol Governance
(define-constant CONTRACT-OWNER tx-sender)

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-INSUFFICIENT-BALANCE (err u1002))
(define-constant ERR-VAULT-NOT-FOUND (err u1003))
(define-constant ERR-INVALID-AMOUNT (err u1004))
(define-constant ERR-UNSAFE-COLLATERAL-RATIO (err u1005))
(define-constant ERR-PROTECTION-ALREADY-ENABLED (err u1006))
(define-constant ERR-PROTECTION-NOT-ENABLED (err u1007))
(define-constant ERR-THRESHOLD-OUT-OF-RANGE (err u1008))
(define-constant ERR-TREASURY-INSUFFICIENT (err u1009))
(define-constant ERR-PROTOCOL-PAUSED (err u1010))
(define-constant ERR-INVALID-VAULT-OWNER (err u1011))
(define-constant ERR-INVALID-DELEGATE (err u1012))

;; Risk Management Parameters (basis points: 10000 = 100%)
(define-constant MIN-SAFE-COLLATERAL-RATIO u1500)  ;; 150% minimum safe collateralization
(define-constant LIQUIDATION-THRESHOLD u1200)       ;; 120% liquidation threshold
(define-constant PROTOCOL-FEE-RATE u100)            ;; 1% protocol fee
(define-constant BASIS-POINTS u10000)               ;; 100% in basis points

;; DATA VARIABLES - Protocol State

(define-data-var protocol-active bool true)
(define-data-var total-protected-collateral uint u0)
(define-data-var treasury-balance uint u0)
(define-data-var liquidation-event-counter uint u1)

;; DATA MAPS - Storage Structures

;; Vault Position Tracking
(define-map vaults
  principal
  {
    collateral-amount: uint,
    debt-amount: uint,
    protection-enabled: bool,
    last-update-height: uint,
    total-fees-paid: uint
  }
)

;; Protection Configuration per Vault
(define-map protection-settings
  principal
  {
    auto-top-up-enabled: bool,
    emergency-contact: (optional principal),
    max-top-up-amount: uint,
    alert-threshold: uint
  }
)

;; Liquidation Event History
(define-map liquidation-events
  uint
  {
    vault-owner: principal,
    debt-repaid: uint,
    collateral-seized: uint,
    event-height: uint,
    was-protected: bool
  }
)

;; READ-ONLY FUNCTIONS - Data Queries

;; Retrieve vault position data
(define-read-only (get-vault-info (owner principal))
  (default-to
    {
      collateral-amount: u0,
      debt-amount: u0,
      protection-enabled: false,
      last-update-height: u0,
      total-fees-paid: u0
    }
    (map-get? vaults owner)
  )
)

;; Calculate current collateralization ratio
(define-read-only (get-collateral-ratio (owner principal))
  (let (
    (vault (get-vault-info owner))
    (collateral (get collateral-amount vault))
    (debt (get debt-amount vault))
  )
    (if (is-eq debt u0)
      (ok u0)
      (ok (/ (* collateral BASIS-POINTS) debt))
    )
  )
)



;; Get protection configuration for a vault
(define-read-only (get-protection-config (owner principal))
  (default-to
    {
      auto-top-up-enabled: false,
      emergency-contact: none,
      max-top-up-amount: u0,
      alert-threshold: u1300
    }
    (map-get? protection-settings owner)
  )
)

;; Calculate protocol fee for a given amount
(define-read-only (calculate-protocol-fee (amount uint))
  (/ (* amount PROTOCOL-FEE-RATE) BASIS-POINTS)
)

;; Get overall protocol statistics
(define-read-only (get-protocol-stats)
  {
    total-protected-collateral: (var-get total-protected-collateral),
    treasury-balance: (var-get treasury-balance),
    protocol-active: (var-get protocol-active),
    min-safe-ratio: MIN-SAFE-COLLATERAL-RATIO,
    liquidation-threshold: LIQUIDATION-THRESHOLD
  }
)

;; Retrieve liquidation event details
(define-read-only (get-liquidation-event (event-id uint))
  (map-get? liquidation-events event-id)
)

;; PRIVATE FUNCTIONS - Internal Helpers

;; Validate vault owner is not sender (prevent self-reference)
(define-private (is-valid-vault-owner (owner principal))
  (not (is-eq owner tx-sender))
)

;; Validate optional principal parameter
(define-private (is-valid-optional-principal (principal-opt (optional principal)))
  (match principal-opt
    p (is-valid-vault-owner p)
    true
  )
)

;; PUBLIC FUNCTIONS - Collateral Management

;; Deposit collateral into vault
(define-public (deposit-collateral (amount uint))
  (let (
    (current-vault (get-vault-info tx-sender))
    (new-collateral (+ (get collateral-amount current-vault) amount))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    
    ;; Transfer STX from user to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Update vault with new collateral
    (map-set vaults tx-sender
      (merge current-vault {
        collateral-amount: new-collateral,
        last-update-height: stacks-block-height
      })
    )
    
    ;; Update protocol metrics
    (var-set total-protected-collateral
      (+ (var-get total-protected-collateral) amount))
    
    (ok new-collateral)
  )
)

;; Withdraw collateral from vault
(define-public (withdraw-collateral (amount uint))
  (let (
    (current-vault (get-vault-info tx-sender))
    (current-collateral (get collateral-amount current-vault))
    (current-debt (get debt-amount current-vault))
    (remaining-collateral (- current-collateral amount))
  )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= current-collateral amount) ERR-INSUFFICIENT-BALANCE)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    
    ;; Ensure withdrawal maintains safe collateral ratio
    (if (> current-debt u0)
      (asserts!
        (>= (/ (* remaining-collateral BASIS-POINTS) current-debt)
            MIN-SAFE-COLLATERAL-RATIO)
        ERR-UNSAFE-COLLATERAL-RATIO)
      true
    )
    
    ;; Transfer STX from contract to user
    (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
    
    ;; Update vault with reduced collateral
    (map-set vaults tx-sender
      (merge current-vault {
        collateral-amount: remaining-collateral,
        last-update-height: stacks-block-height
      })
    )
    
    ;; Update protocol metrics
    (var-set total-protected-collateral
      (- (var-get total-protected-collateral) amount))
    
    (ok remaining-collateral)
  )
)

;; PUBLIC FUNCTIONS - Debt Management

;; Update vault debt (external oracle integration point)
(define-public (update-vault-debt (vault-owner principal) (new-debt uint))
  (let (
    (vault (get-vault-info vault-owner))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    (asserts! (is-valid-vault-owner vault-owner) ERR-INVALID-VAULT-OWNER)
    
    ;; Update vault debt information
    (map-set vaults vault-owner
      (merge vault {
        debt-amount: new-debt,
        last-update-height: stacks-block-height
      })
    )
    
    (ok new-debt)
  )
)

;; PUBLIC FUNCTIONS - Protection Services

;; Enable protection for vault
(define-public (enable-protection)
  (let (
    (vault (get-vault-info tx-sender))
    (collateral (get collateral-amount vault))
    (fee (calculate-protocol-fee collateral))
  )
    (asserts! (not (get protection-enabled vault)) ERR-PROTECTION-ALREADY-ENABLED)
    (asserts! (> collateral u0) ERR-INSUFFICIENT-BALANCE)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    
    ;; Collect protection fee
    (try! (stx-transfer? fee tx-sender (as-contract tx-sender)))
    
    ;; Enable protection and record fee
    (map-set vaults tx-sender
      (merge vault {
        protection-enabled: true,
        total-fees-paid: (+ (get total-fees-paid vault) fee),
        last-update-height: stacks-block-height
      })
    )
    
    ;; Add fee to treasury
    (var-set treasury-balance (+ (var-get treasury-balance) fee))
    
    (ok true)
  )
)

;; Disable protection for vault
(define-public (disable-protection)
  (let (
    (vault (get-vault-info tx-sender))
  )
    (asserts! (get protection-enabled vault) ERR-PROTECTION-NOT-ENABLED)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    
    ;; Disable protection
    (map-set vaults tx-sender
      (merge vault {
        protection-enabled: false,
        last-update-height: stacks-block-height
      })
    )
    
    (ok false)
  )
)

;; PUBLIC FUNCTIONS - Configuration

;; Configure protection parameters
(define-public (configure-protection
  (enable-auto-top-up bool)
  (emergency-contact (optional principal))
  (max-top-up uint)
  (alert-threshold uint)
)
  (begin
    (asserts!
      (and (>= alert-threshold LIQUIDATION-THRESHOLD)
           (<= alert-threshold MIN-SAFE-COLLATERAL-RATIO))
      ERR-THRESHOLD-OUT-OF-RANGE)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    (asserts! (is-valid-optional-principal emergency-contact) ERR-INVALID-DELEGATE)
    (asserts! (<= max-top-up u1000000000000) ERR-INVALID-AMOUNT)
    
    (map-set protection-settings tx-sender {
      auto-top-up-enabled: enable-auto-top-up,
      emergency-contact: emergency-contact,
      max-top-up-amount: max-top-up,
      alert-threshold: alert-threshold
    })
    
    (ok true)
  )
)

;; PUBLIC FUNCTIONS - Emergency Response

;; Execute emergency top-up for at-risk vault
(define-public (emergency-top-up (vault-owner principal) (amount uint))
  (let (
    (vault (get-vault-info vault-owner))
    (config (get-protection-config vault-owner))
    (current-ratio (unwrap! (get-collateral-ratio vault-owner) ERR-VAULT-NOT-FOUND))
  )
    (asserts! (get protection-enabled vault) ERR-PROTECTION-NOT-ENABLED)
    (asserts! (< current-ratio (get alert-threshold config)) ERR-THRESHOLD-OUT-OF-RANGE)
    (asserts! (<= amount (get max-top-up-amount config)) ERR-INVALID-AMOUNT)
    (asserts! (>= (var-get treasury-balance) amount) ERR-TREASURY-INSUFFICIENT)
    (asserts! (var-get protocol-active) ERR-PROTOCOL-PAUSED)
    
    ;; Deduct from treasury
    (var-set treasury-balance (- (var-get treasury-balance) amount))
    
    ;; Add collateral to vault
    (map-set vaults vault-owner
      (merge vault {
        collateral-amount: (+ (get collateral-amount vault) amount),
        last-update-height: stacks-block-height
      })
    )
    
    (ok amount)
  )
)

;; PUBLIC FUNCTIONS - Liquidation Tracking

;; Record liquidation event
(define-public (record-liquidation
  (vault-owner principal)
  (debt-repaid uint)
  (collateral-seized uint)
)
  (let (
    (event-id (var-get liquidation-event-counter))
    (vault (get-vault-info vault-owner))
    (was-protected (get protection-enabled vault))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-vault-owner vault-owner) ERR-INVALID-VAULT-OWNER)
    (asserts! (<= debt-repaid u1000000000000) ERR-INVALID-AMOUNT)
    (asserts! (<= collateral-seized u1000000000000) ERR-INVALID-AMOUNT)
    
    ;; Store liquidation event
    (map-set liquidation-events event-id {
      vault-owner: vault-owner,
      debt-repaid: debt-repaid,
      collateral-seized: collateral-seized,
      event-height: stacks-block-height,
      was-protected: was-protected
    })
    
    ;; Increment event counter
    (var-set liquidation-event-counter (+ event-id u1))
    
    ;; Update or remove vault
    (if (>= collateral-seized (get collateral-amount vault))
      (map-delete vaults vault-owner)
      (map-set vaults vault-owner
        (merge vault {
          collateral-amount: (- (get collateral-amount vault) collateral-seized),
          debt-amount: (if (>= debt-repaid (get debt-amount vault))
                          u0
                          (- (get debt-amount vault) debt-repaid)),
          protection-enabled: false,
          last-update-height: stacks-block-height
        })
      )
    )
    
    (ok event-id)
  )
)

;; PUBLIC FUNCTIONS - Administration

;; Toggle protocol active state
(define-public (toggle-protocol-state)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set protocol-active (not (var-get protocol-active)))
    (ok (var-get protocol-active))
  )
)

;; Withdraw from treasury (admin only)
(define-public (withdraw-from-treasury (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (>= (var-get treasury-balance) amount) ERR-INSUFFICIENT-BALANCE)
    
    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT-OWNER)))
    (var-set treasury-balance (- (var-get treasury-balance) amount))
    
    (ok amount)
  )
)