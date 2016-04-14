#lang racket
(require racket/udp
         racket/cmdline
         racket/trace
         "common.rkt")

;; Input: filepath : path? : The filepath to write the file to.
;;        sendsock : udp? : The connected socket to the server
;;        recvsock : udp? : The socket to receive data from
;; Client-side routine to receive files according to the alternating-bit protocol
(define (alt-bit-recv filepath sendsock recvsock)
  (define outfile (open-output-file (string->path filepath)
                                    #:mode 'binary
                                    #:exists 'replace))
  (define inbytes (make-bytes 506))
  (define pkt (udpseg #f #f 0 (bytes)))
  (define ackpkt (bytes))
  (define expseq 0)
  (define resendack #f)
  
  (for ([i (in-naturals)]
        #:break (if (list? (sync/timeout 1 (udp-receive!-evt recvsock inbytes)))
                    ;; We got some data, set it up for parsing.
                    (begin
                      ;(displayln inbytes)
                      (set! pkt (udpseg #f #f 0 (bytes)))
                      (set! pkt (parse-datagram inbytes))
                      (set! resendack #f)
                      (udpseg-eofile pkt))
                    ;; Didn't get the data in time, we're resending the ack
                    (begin
                      (set! resendack #t)   
                      #f))
        )
    (if resendack
        ;; Resend the last ackpkt to warrant a new data packet.
        (begin
          (displayln "NO DATA RECEIVED, RESENDING LAST ACK...")
          (udp-send sendsock ackpkt)
          )
        ;; Otherwise do the regular stuff to the packet
        ;; Check that the datagram has the expected seqnum
        (if (= expseq (udpseg-seqnum pkt))
            ;; It has the expected seqnum
            (begin
              ;; Toggle the expected seqnum and do our stuff to the data.
              (set! expseq (toggle-seqnum (udpseg-seqnum pkt)))
              ;; Write datagram contents to the output file
              ;(display inbytes outfile)
              (display (udpseg-data pkt) outfile)
              ;; Build the ACK datagram
              (set! ackpkt (build-pkt #t #f (udpseg-seqnum pkt) (bytes)))
              (udp-send sendsock ackpkt))
            ;; It does not. We do nothing in this case.
            null)
        )
    )
  ;; Once the file is done being written, close the file port and return
  ;; control to the main process
  (close-output-port outfile)
  )
;(trace alt-bit-recv)
(let ((sock (udp-open-socket))
      (recvsock (udp-open-socket))
      (recvbytes (make-bytes 500))
      (sendbytes (bytes)))

  (define-values (serverip filepath sendport cmdline-reqfile) (command-line #:args (ip filename sendport cmdline-reqfile) (values ip filename sendport cmdline-reqfile)))
  
  ;; Set up the UDP socket to connect to the server
  ;; Set up a UDP socket to receive the response from the server.
  (udp-connect! sock serverip 5050)
  (udp-bind! recvsock #f (string->number sendport))
  
  ;; Send our initial datagram. Here the return port and file are hard-coded
  (set! sendbytes (build-pkt #f #f 1234 (string->bytes/utf-8 (string-append sendport "::" cmdline-reqfile "::"))))
  
  ;; Repeatedly loop until we receive a response from the server.
  (for ([i (in-naturals)]
    #:break (list? (sync/timeout 1 (udp-receive!-evt recvsock recvbytes))))
    (displayln "SENDING REQ PACKET...")
    (udp-send sock sendbytes))
  
  ;; Prettily display what the server sends back to us.
  (let ((pkt (parse-datagram recvbytes)))
    (displayln "RESPONSE FROM SERVER:")
    (displayln (list "ACK:" (udpseg-ack pkt)))
    (displayln (list "EOF:" (udpseg-eofile pkt)))
    (displayln (list "SEQ:" (udpseg-seqnum pkt)))
    (displayln (list "DATA:" (udpseg-data pkt)))
    (if (udpseg-ack pkt)
        (alt-bit-recv filepath sock recvsock)
        (begin
          (displayln "FILE NOT FOUND OR FILE EMPTY")
          (exit)))
    )
  ;; Once we're here again, the file has (presumably) finished transferring.
  ;; Now we send our ACKEOF to the server.
  (displayln "FILE RECEIVED. SENDING ACKEOF")
  (udp-send sock (build-pkt #t #t 0 (bytes)))
  ;; And await the server's ACKEOF, resending ours if necessary.
  (for ([i (in-naturals)]
        #:break (begin
                  (let ((finbytes (make-bytes 100))
                        (finpkt (udpseg #f #f 0 (bytes))))
                    (if (list? (sync/timeout 1 (udp-receive!-evt recvsock finbytes)))
                        (begin
                          (set! finpkt (parse-datagram finbytes))
                          (and (udpseg-ack finpkt) (udpseg-eofile finpkt))
                          )
                        (begin
                          (udp-send sock (build-pkt #t #t 0 (bytes)))
                          #f)))))
    null)
  (exit)
  )

