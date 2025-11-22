;; Risk Prediction Engine for DeFi Vaults
;; This contract provides a comprehensive risk assessment system for DeFi vaults,
;; evaluating multiple risk factors including liquidity, volatility, concentration,
;; and historical performance to generate risk scores and predictions.

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-vault-not-found (err u101))
(define-constant err-invalid-score (err u102))
(define-constant err-unauthorized (err u103))
(define-constant err-invalid-parameters (err u104))
(define-constant err-vault-exists (err u105))

;; Risk thresholds (scaled by 100 for precision)
(define-constant risk-threshold-low u3000)      ;; 30%
(define-constant risk-threshold-medium u6000)   ;; 60%
(define-constant risk-threshold-high u8500)     ;; 85%

;; Weight factors for risk calculation (total = 100)
(define-constant weight-liquidity u25)
(define-constant weight-volatility u30)
(define-constant weight-concentration u20)
(define-constant weight-historical u25)

;; data maps and vars
(define-map vaults
    { vault-id: uint }
    {
        owner: principal,
        total-value-locked: uint,
        liquidity-score: uint,
        volatility-score: uint,
        concentration-score: uint,
        historical-score: uint,
        overall-risk-score: uint,
        risk-level: (string-ascii 10),
        last-updated: uint,
        is-active: bool
    }
)

(define-map vault-metrics
    { vault-id: uint }
    {
        daily-volume: uint,
        unique-depositors: uint,
        largest-position-pct: uint,
        drawdown-30d: uint,
        sharpe-ratio: uint,
        total-incidents: uint
    }
)

(define-map risk-assessors
    { assessor: principal }
    { authorized: bool, assessments-count: uint }
)

(define-data-var vault-counter uint u0)
(define-data-var total-vaults-assessed uint u0)
(define-data-var protocol-risk-score uint u5000)

;; private functions

;; Calculate weighted risk score from individual components
(define-private (calculate-overall-risk 
    (liquidity uint) 
    (volatility uint) 
    (concentration uint) 
    (historical uint))
    (let
        (
            (weighted-liquidity (/ (* liquidity weight-liquidity) u100))
            (weighted-volatility (/ (* volatility weight-volatility) u100))
            (weighted-concentration (/ (* concentration weight-concentration) u100))
            (weighted-historical (/ (* historical weight-historical) u100))
        )
        (+ weighted-liquidity 
           (+ weighted-volatility 
              (+ weighted-concentration weighted-historical)))
    )
)

;; Determine risk level based on score
(define-private (get-risk-level (score uint))
    (if (< score risk-threshold-low)
        "low"
        (if (< score risk-threshold-medium)
            "medium"
            (if (< score risk-threshold-high)
                "high"
                "critical"
            )
        )
    )
)

;; Validate score is within acceptable range (0-10000 representing 0-100%)
(define-private (is-valid-score (score uint))
    (<= score u10000)
)

;; Calculate liquidity risk based on TVL and daily volume
(define-private (assess-liquidity-risk (tvl uint) (daily-volume uint))
    (let
        (
            (volume-ratio (if (> tvl u0) (/ (* daily-volume u10000) tvl) u10000))
        )
        ;; Higher volume ratio = lower risk
        (if (> volume-ratio u5000)
            u2000  ;; Low risk: 20%
            (if (> volume-ratio u2000)
                u5000  ;; Medium risk: 50%
                u8000  ;; High risk: 80%
            )
        )
    )
)

;; public functions

;; Register a new vault for risk assessment
(define-public (register-vault (tvl uint))
    (let
        (
            (new-vault-id (+ (var-get vault-counter) u1))
        )
        (asserts! (is-none (map-get? vaults { vault-id: new-vault-id })) err-vault-exists)
        (asserts! (> tvl u0) err-invalid-parameters)
        
        (map-set vaults
            { vault-id: new-vault-id }
            {
                owner: tx-sender,
                total-value-locked: tvl,
                liquidity-score: u5000,
                volatility-score: u5000,
                concentration-score: u5000,
                historical-score: u5000,
                overall-risk-score: u5000,
                risk-level: "medium",
                last-updated: block-height,
                is-active: true
            }
        )
        
        (map-set vault-metrics
            { vault-id: new-vault-id }
            {
                daily-volume: u0,
                unique-depositors: u0,
                largest-position-pct: u0,
                drawdown-30d: u0,
                sharpe-ratio: u0,
                total-incidents: u0
            }
        )
        
        (var-set vault-counter new-vault-id)
        (ok new-vault-id)
    )
)

;; Authorize a risk assessor
(define-public (authorize-assessor (assessor principal))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (ok (map-set risk-assessors
            { assessor: assessor }
            { authorized: true, assessments-count: u0 }
        ))
    )
)

;; Update vault risk scores (only authorized assessors)
(define-public (update-risk-scores 
    (vault-id uint)
    (liquidity uint)
    (volatility uint)
    (concentration uint)
    (historical uint))
    (let
        (
            (vault (unwrap! (map-get? vaults { vault-id: vault-id }) err-vault-not-found))
            (assessor-data (unwrap! (map-get? risk-assessors { assessor: tx-sender }) err-unauthorized))
            (overall-score (calculate-overall-risk liquidity volatility concentration historical))
            (risk-level (get-risk-level overall-score))
        )
        (asserts! (get authorized assessor-data) err-unauthorized)
        (asserts! (and (is-valid-score liquidity) 
                      (is-valid-score volatility)
                      (is-valid-score concentration)
                      (is-valid-score historical)) err-invalid-score)
        
        (map-set vaults
            { vault-id: vault-id }
            (merge vault {
                liquidity-score: liquidity,
                volatility-score: volatility,
                concentration-score: concentration,
                historical-score: historical,
                overall-risk-score: overall-score,
                risk-level: risk-level,
                last-updated: block-height
            })
        )
        
        (map-set risk-assessors
            { assessor: tx-sender }
            (merge assessor-data { assessments-count: (+ (get assessments-count assessor-data) u1) })
        )
        
        (var-set total-vaults-assessed (+ (var-get total-vaults-assessed) u1))
        (ok overall-score)
    )
)

;; Get vault risk information
(define-read-only (get-vault-risk (vault-id uint))
    (ok (unwrap! (map-get? vaults { vault-id: vault-id }) err-vault-not-found))
)

;; Get vault metrics
(define-read-only (get-vault-metrics (vault-id uint))
    (ok (unwrap! (map-get? vault-metrics { vault-id: vault-id }) err-vault-not-found))
)

;; Check if vault is high risk
(define-read-only (is-high-risk (vault-id uint))
    (let
        (
            (vault (unwrap! (map-get? vaults { vault-id: vault-id }) err-vault-not-found))
        )
        (ok (>= (get overall-risk-score vault) risk-threshold-medium))
    )
)

;; Get protocol-wide risk score
(define-read-only (get-protocol-risk)
    (ok (var-get protocol-risk-score))
)

;; Advanced Risk Prediction with Machine Learning-inspired Scoring
;; This function implements a comprehensive risk prediction algorithm that analyzes
;; multiple data points and applies weighted scoring with decay factors for time-sensitive metrics.
;; It simulates a predictive model by incorporating historical trends, current metrics,
;; and forward-looking indicators to generate a risk forecast for the next 30 days.
(define-public (predict-future-risk
    (vault-id uint)
    (projected-tvl-change int)
    (projected-volatility-change int)
    (market-sentiment-score uint)
    (protocol-health-score uint))
    (let
        (
            (vault (unwrap! (map-get? vaults { vault-id: vault-id }) err-vault-not-found))
            (metrics (unwrap! (map-get? vault-metrics { vault-id: vault-id }) err-vault-not-found))
            (current-risk (get overall-risk-score vault))
            
            ;; Calculate TVL impact (positive change reduces risk, negative increases it)
            (tvl-impact (if (> projected-tvl-change 0)
                (/ (to-uint projected-tvl-change) u10)
                (/ (to-uint (* projected-tvl-change -1)) u5)))
            
            ;; Calculate volatility impact (always increases risk)
            (volatility-impact (if (> projected-volatility-change 0)
                (/ (to-uint projected-volatility-change) u3)
                u0))
            
            ;; Market sentiment adjustment (0-10000 scale, lower is better)
            (sentiment-adjustment (/ (- u10000 market-sentiment-score) u20))
            
            ;; Protocol health factor (0-10000 scale, higher is better)
            (health-factor (/ (- u10000 protocol-health-score) u15))
            
            ;; Historical incident penalty
            (incident-penalty (* (get total-incidents metrics) u100))
            
            ;; Concentration risk amplifier
            (concentration-amplifier (if (> (get largest-position-pct metrics) u3000)
                u500
                u0))
            
            ;; Calculate predicted risk score
            (base-prediction current-risk)
            (adjusted-prediction (+ base-prediction 
                (+ volatility-impact 
                   (+ sentiment-adjustment 
                      (+ health-factor 
                         (+ incident-penalty concentration-amplifier))))))
            (final-prediction (if (> adjusted-prediction tvl-impact)
                (- adjusted-prediction tvl-impact)
                u0))
            
            ;; Cap prediction at maximum risk score
            (capped-prediction (if (> final-prediction u10000) u10000 final-prediction))
            (predicted-risk-level (get-risk-level capped-prediction))
        )
        ;; Validate input parameters
        (asserts! (is-valid-score market-sentiment-score) err-invalid-parameters)
        (asserts! (is-valid-score protocol-health-score) err-invalid-parameters)
        (asserts! (get is-active vault) err-vault-not-found)
        
        ;; Return comprehensive prediction result
        (ok {
            current-risk-score: current-risk,
            predicted-risk-score: capped-prediction,
            predicted-risk-level: predicted-risk-level,
            risk-change: (if (> capped-prediction current-risk)
                (- capped-prediction current-risk)
                u0),
            recommendation: (if (>= capped-prediction risk-threshold-high)
                "URGENT: Consider reducing exposure"
                (if (>= capped-prediction risk-threshold-medium)
                    "WARNING: Monitor closely"
                    "SAFE: Continue normal operations"
                ))
        })
    )
)


