#lang racket
(require racket/udp
         racket/trace)

(struct udpseg (ack eofile seqnum data) #:mutable)

;; Input: ack : bool? : Whether the packet has ack on/off
;;        eofile : bool? : Whether the packet has eof on/off
;;        seqnum : integer? : The sequence number of the packet
;;        data : bytes? : The data to be sent
;; Output: A bytestring that can be sent via UDP
;; A function to construct a packet to send via UDP
(define (build-pkt ack eofile seqnum data)
  (define retbytes (bytes))
  (let ((flags 0))
    (cond
      [(and ack eofile) (set! flags 3)]
      [ack (set! flags 1)]
      [eofile (set! flags 2)])
    (set! retbytes (bytes-append retbytes (integer->integer-bytes flags 2 #f))))
  (set! retbytes (bytes-append retbytes (integer->integer-bytes seqnum 4 #f)))
  (set! retbytes (bytes-append retbytes data))
  retbytes
  )

;; Parses a datagram from UDP.
;; input: bytes? : a bytestring representing data gotten from UDP
;; output:  udpseg? : a struct representing the flags, data from that datagram
(define (parse-datagram bytebuf)
  (define dtg (udpseg #f #f 0 0))
  (let ((num (integer-bytes->integer (subbytes bytebuf 0 2) #f)))
    (cond
      [(= 0 num)]
      [(= 1 num) (set-udpseg-ack! dtg #t)]
      [(= 2 num) (set-udpseg-eofile! dtg #t)]
      [(= 3 num) (begin
                   (set-udpseg-ack! dtg #t)
                   (set-udpseg-eofile! dtg #t))]))
  (set-udpseg-seqnum! dtg (integer-bytes->integer (subbytes bytebuf 2 6) #f))
  (set-udpseg-data! dtg (subbytes bytebuf 6))
  dtg)

;; Very simple function to return the opposite sequence number
;; for the alternating-bit protocol.
(define (toggle-seqnum seqnum)
  (cond
    [(= 0 seqnum) 1]
    [(= 1 seqnum) 0])
  )

(provide (all-defined-out))
