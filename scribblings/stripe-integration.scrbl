#lang scribble/manual
@require[@for-label[stripe-integration
                    json
                    racket/base
		    racket/dict]]

@title{Lightweight Stripe API Library}
@author{Sage Lennon Gerard}

@defmodule[stripe-integration]

An unofficial client of the Stripe API for use in Racket.

Tested against API version 2019-09-09.

Includes exponential backoff when Stripe's servers request it,
and idempotency key handling for sensitive calls.


@section{Why not just @racket[stripe]?}

Because that's not my trademark and I wanted a name
that hit a sweet spot between:

@itemlist[
@item{being searchable on a package index that lacks the integration outright, and;}
@item{respecting a name that should be available to its rightful owner.}
]

I found an example of other unofficial libraries taking a similar approach,
and Stripe @hyperlink["https://stripe.com/docs/libraries#third-party" "keeps links to them"].
For that reason I'll use this name unless I am asked to change it.

@section{Idempotency keys?}

An @hyperlink["https://stripe.com/docs/api/idempotent_requests?lang=curl" @italic{idempotency key}] is Stripe's answer for how to handle
when you, say, lose network connectivity right before the API
tells you that a credit card transaction was complete. Instead of
tangental validation or trying to incur a new charge, you can instead
provide an idempotency key to a new request and Stripe will provide
the same response it has available for you on the old call.


@section{Client API Reference}

@defthing[stripe-host "api.stripe.com"]{
The Stripe API host.
}

@defthing[stripe-endpoint (parameter/c string?) #:value stripe-host]{
The endpoint used for requests against the Stripe API. Change this to use a mock host.
}

@defthing[stripe-secret-key (parameter/c string?) #:value ""]{
The secret key to use when authenticating requests with the Stripe API.
Use @racket[parameterize] to limit the time this spends visible to other
client modules.
}

@defthing[stripe-bearer? (parameter/c boolean?) #:value #f]{
If @racket[#t], requests will use bearer authentication.
Otherwise, it will use basic authentication.
}

@defthing[stripe-request-procedure/c
          (unconstrained-domain-> exact-positive-integer?
                                  dict?
                                  jsexpr?
				  (or/c boolean? string?))]{
This contract applies to the below HTTP helper procedures. They each return
the following 4 values, in order:

@itemlist[#:style 'ordered
@item{The HTTP status code, as an exact positive integer.}
@item{A dict of headers such that the keys are header names as all lower-case interned symbols. This is to eliminate ambiguity on casing rules and allow @racket[eq?] tests.}
@item{A @racket[jsexpr] representing the JSON response to a Stripe API request.}
@item{A generated idempotency key used to resume sensitive operations on Stripe using non-idempotent requests. For GET and DELETE requests, this is always @racket[#f]. See the Stripe API reference for more information.}
]
}

@defstruct[(exn:fail:stripe exn:fail) ([idempotency-key (or/c string? boolean?)]
                                       [wrapped-exn exn?])]{
An exception that wraps another in response to interrupted network connections.

This is thrown by the HTTP request procedures below when a connection to Stripe
is interrupted. It will contain an idempotency key that you should persist if
this exception came up when attempting a POST that did something sensitive
like charge a customer. The key will help you repeat the request without
repeating something that should only happen once.

@racket[wrapped-exn] is the original exception caught before the @racket[exn:fail:stripe]
instance was raised in the original exception's stead. An instance of @racket[exn:fail:stripe]
has the same continuation marks as @racket[wrapped-exn].
}

@deftogether[(
@defproc[(stripe-get [uri string?]
                     [#:retry? retry? #t]
		     [#:max-tries max-tries 5])
		     (values exact-positive-integer?
                             dict?
               	             jsexpr?
			     (or/c boolean? string?))
		     ]
@defproc[(stripe-delete [uri string?] [#:retry? retry? #t] [#:max-tries max-tries 5])
		     (values exact-positive-integer?
                             dict?
               	             jsexpr?
			     (or/c boolean? string?))
]
@defproc[(stripe-post [uri string?]
                     [data (or/c dict? string?)]
                     [#:retry? retry? #t]
                     [#:max-tries max-tries 5])
		     (values exact-positive-integer?
                             dict?
               	             jsexpr?
			     (or/c boolean? string?))
]
)]{
HTTP helper methods for speaking to the Stripe API.

If @racket[retry?] is @racket[#t], each request will retry
with an exponential backoff if Stripe API responds with
@racket["HTTP 429 - Too Many Requests"]. @racket[retry?] does
not cover network connectivity failure, because
blocking might not be the best approach. The client will make @racket[max-tries]
attempts before throwing @racket[exn:fail], and will wait as many seconds as
defined by this procedure:

@racketblock[
(define (backoff-time n)
  (min (+ (expt 2 n)
          (/ (random 0 1000) 1000)) ; Try to stay out of sync with other clients.
       32))
]

The @racket[data] provided to @racket[post] will be
encoded for use with @racket["Content-Type: application/x-www-form-urlencoded"].
If the value cannot be encoded, @racket[post] will raise @racket[exn:fail:contract].

All POST requests will include a generated idempotency key to protect against
unusual network conditions at bad times (such as when processing a payment).
In the event of a @racket[exn:fail:network], the exact exception will be transformed
into an instance of @racket[exn:fail:stripe] with the same continuation marks
and the idempotency key attached for you to persist.

None of the request procedures will throw an exception in response to 4xx or 5xx
HTTP status codes. If the response reports an error, it is still a response and
will simply be returned as such.
}

@section{Simple example}

This follows the @hyperlink["https://stripe.com/docs/api/authentication?lang=curl" "authentication example in the Stripe API reference"].

@racketblock[
(require stripe-integration json)
(stripe-secret-key "test_blahblahblah")

(define-values (status headers json ik) (stripe-get "/v1/charges"))
]

From this you can follow along in the reference using the other request procedures.
