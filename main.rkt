#lang racket/base

(module+ test
  (require rackunit))

(provide
 (struct-out exn:fail:stripe)
 (prefix-out stripe-
             (combine-out
               get
               post
               delete
               host
               endpoint
               request-procedure/c
               secret-key
               bearer?)))

(require json
         racket/contract
         racket/dict
         racket/function
         racket/random
         racket/string         
         net/base64
         net/http-client
         net/uri-codec)

(define host "api.stripe.com")
(define endpoint (make-parameter host))
(define secret-key (make-parameter #f))
(define bearer? (make-parameter #f))
(define request-procedure/c (unconstrained-domain->
                             exact-positive-integer?
                             dict?
                             jsexpr?
                             (or/c boolean? string?)))

(define-struct (exn:fail:stripe exn:fail)
  (idempotency-key wrapped-exn))

(define (backoff-time n)
  (min (+ (expt 2 n)
          (/ (random 0 1000) 1000)) ; Try to stay out of sync with other clients.
       32))

; Will consider this decent-enough entropy to avoid uuid dependency
(define (make-idempotency-key)
  (base64-encode (crypto-random-bytes 20) #""))

;; -----------------------------------------------------
;; Headers

(define (make-header name val)
  (string-append name ": " val))

(define idempotency-header
  (curry make-header "Idempotency-Key"))

(define (basic-auth-header)
  (make-header "Authorization"
               (string-append "Basic "
                              (bytes->string/utf-8
                               (base64-encode
                                (string->bytes/utf-8
                                 (string-append (secret-key) ":"))
                                #"")))))

(define (bearer-header)
  (make-header "Authorization"
               (string-append "Bearer " (secret-key))))


;; -----------------------------------------------------
;; HTTP response bytes to useful Racket values with
;; UTF-8 strings.

(define (get-status-code status-line)
  (string->number (cadr (string-split (bytes->string/utf-8 status-line) " "))))

(define (headers->hasheq headers)
  (for/fold ([h #hasheq()])
            ([header (in-list headers)])
    (define as-string (bytes->string/utf-8 header))
    (define split (string-split as-string ":"))
    (hash-set h
              (string->symbol (string-downcase (car split)))
              (string-trim (cadr split)))))


;; ---------------------------------------------------------
;; Meat of the Stripe API integration

(define (request method
                 uri
                 #:idempotency-key [ik #f]
                 #:data [data #f]
                 #:retry? [retry? #t]
                 #:max-tries [max-tries 5])
  ; An idempotency key only matters for methods that are not idempotent.
  (define idempotent-method?
    (or (equal? "GET" method)
        (equal? "DELETE" method)))

  (define idempotency-key
    (if idempotent-method?
        #f
        (or ik (make-idempotency-key))))

  (define headers '("Accept: application/json"))

  (define headers/content-type
    (cons (if (equal? method "POST")
              "Content-Type: application/x-www-form-urlencoded"
              "Content-Type: application/json")
          headers))

  (define headers/auth (cons
                        (if (bearer?)
                            (bearer-header)
                            (basic-auth-header))
                        headers/content-type))

  (define headers/idempotency
    (if (string? ik)
        (cons (idempotency-header ik)
              headers/auth)
        headers/auth))

  (let loop ([attempt 0])
    (when (= attempt max-tries)
      (error "Maximum tries reached: ~a" attempt))
    
    (with-handlers ([exn:fail:network?
                     (λ (e)
                       (raise (make-exn:fail:stripe
                               (format (string-append
                                        "Network error when communicating with Stripe.~n"
                                        "Wrapped exception message:~n  ~a")
                                       (exn-message e))                                        
                               (exn-continuation-marks e)
                               idempotency-key
                               e)))])
      (define-values (status resp-headers body)
        (http-sendrecv (endpoint)
                       uri
                       #:ssl? #t
                       #:port 443
                       #:method method
                       #:headers headers/idempotency
                       #:data data))

      (define status-code (get-status-code status))
      (if (and (= 429 status-code) retry?)
          (begin
            (sleep (backoff-time attempt))
            (loop (add1 attempt)))
          (values
           status-code
           (headers->hasheq resp-headers)
           (read-json body)
           idempotency-key)))))


;; ---------------------------------------------------------
;; Friendly names for the user. Not including PUT/PATCH
;; because Stripe seems to avoid using those in recent
;; API versions. Will add them if user feedback calls for it.
;;
;; OPTIONS/HEAD/TRACE are easy enough to hit independently.

(define (get uri #:retry? [retry? #t] #:max-tries [max-tries 5])
  (request "GET" uri #:retry? retry? #:max-tries max-tries))

(define (delete uri #:retry? [retry? #t] #:max-tries [max-tries 5])
  (request "DELETE" uri #:retry? retry? #:max-tries max-tries))

(define (post uri data
              #:idempotency-key [ik #f]
              #:retry? [retry? #t]
              #:max-tries [max-tries 5])
  (request "POST"
           uri
           #:idempotency-key ik
           #:retry? retry?
           #:max-tries max-tries
           #:data (if (dict? data)
                      (alist->form-urlencoded (dict->list data))
                      (form-urlencoded-encode data))))
