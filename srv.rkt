#lang racket
(require racket/udp
         racket/trace
         "common.rkt")

;; Define a struct to remember the clients that contact us.
(struct udp-client (ip port) #:mutable)

;; Simple function to make the rest of the code a little prettier.
(define (trim-buffer inbytes numbytes)
  (subbytes inbytes 0 numbytes))

;; We format our segment in three pieces, according to this schema: <port>::<data>::
;; From our data segment, retrieve the port it was sent to us from.
(define (get-ret-port bytestr)
  (let ((workstr (bytes->string/utf-8 bytestr)))
    (string->number (car (string-split workstr "::"))))
  )

;; Input: reqfile : path? : The path of the file we want to send
;;        return-sock : udp? : A connected socket to the client
;;        receive-sock : udp? : The socket the client sent the request to.
;; Server-side routine to send files according to the alternating-bit protocol
(define (alt-bit-send reqfile return-sock receive-sock)
  ;; Network-level arguments. We set it to 500 to be conservative.
  (define mtusize 500)
  (define filebuf (make-bytes mtusize))
  
  ;; Open the file to read, make a byte-buffer
  (define infile (open-input-file reqfile))
  (define inbytes (make-bytes mtusize))
  
  ;;
  (define expseq 0)  
  (define resendpkt? #f)
  (define datapkt (udpseg #f #f 0 (bytes)))
  (define ackpkt (udpseg #f #f 0 (bytes)))

  (define tmpval #f)
  ;; Send the first data packet
  (set! datapkt (build-pkt #f
                           #f
                           expseq
                           (trim-buffer filebuf
                                       (read-bytes! filebuf infile))))
  (displayln "BEGINNING FILE TRANSFER")
  ;(displayln datapkt)
  (udp-send return-sock datapkt)
  
  (for ([i (in-naturals)]
        ;; We have found the end-of-file. Stop sending.
        #:break (eof-object? (peek-bytes mtusize 0 infile)))
    ;; If the result of the sync is a l.ist, we have received something into the socket.
    ;; In that case, we don't need to resend the last packet.
    (set! resendpkt? (begin
                      (set! tmpval (sync/timeout 1 (udp-receive!-evt receive-sock inbytes)))
                      ;; If we got a list, there was something in the socket.
                      ;; So, parse the result.
                      (if (list? tmpval)
                          (set! ackpkt (parse-datagram inbytes))
                          null)
                      
                      ;; If we got something AND it is an ack AND it has the expecte seqnum, we don't need to resend.
                      (if (and (list? tmpval) (udpseg-ack ackpkt) (= expseq (udpseg-seqnum ackpkt)))
                          #f
                          #t)))
    (if resendpkt?
        ;; We need to resend the last packet.
        ;; Notify the console, because the last packet is still in datapkt
        (displayln (format "ACK NOT RECEIVED, RESENDING PKT, SEQ=~a" (expseq)))
        ;; We don't need to resend the last packet.
        ;; We know that it has the right seqnum, too.
        (begin
          ;; Toggle the seqnum, and put the next bytes in the buffer
          (set! expseq (toggle-seqnum expseq))
          (set! datapkt (build-pkt #f #f expseq (trim-buffer filebuf
                                                             (read-bytes! filebuf infile))))))
    ;(displayln datapkt)
    (displayln "SENDING PACKET...")
    (udp-send return-sock datapkt))
  
  ;; Once we're out of the loop we have reached the eofile object in the file.
  ;; Send the initial EOF pkt
  (displayln "SENDING EOF")
  (udp-send return-sock (build-pkt #f #t expseq (bytes)))
  (for ([i (in-naturals)]
        #:break (begin
                  ;; As above, receive a datagram from the client.
                  (set! tmpval (sync/timeout 1 (udp-receive!-evt receive-sock inbytes)))
                  ;; If we got a datagram, parse it.
                  ;; Otherwise, loop back around because it was a timeout.
                  (if (list? tmpval)
                      (set! ackpkt (parse-datagram inbytes))
                      #f
                      )
                  ;; If the datagram was a list AND ACK=1 AND EOFILE=1 then
                  ;; we send our own ACKEOF packet, and break the loop.
                  ;; But we only send it once because of infinite regression issues.
                  (if (and (list? tmpval) (udpseg-ack ackpkt) (udpseg-eofile ackpkt))
                      (begin
                        (set! datapkt (build-pkt #t #t 0 (bytes)))
                        ;(displayln (subbytes datapkt 6))
                        ;(displayln "SENDING PACKET...")
                        (udp-send return-sock datapkt)
                        #t)
                      #f)))
    null
    )
  ;; Once we're here, we could exit the program. But good coding
  ;; will take us back to the top-level so the main routine can exit.
  (displayln "FILE TRANSFER COMPLETE")
  )

;; Input : reqfile : path? : The path of the file we want to send
;;         return-sock : udp? : A connected socket to the client
;;         receive-sock : udp? : The socket the client sent the request to.
;; Server-side routine to send files according to the go-back-n protocol
(define (gbn-send reqfile return-sock receive-sock)
  ;; Define the values for the file operations.
  (define mtusize 500)
  (define filebuf (make-bytes mtusize))
  (define infile (open-input-file reqfile))

  ;; Define the values regarding the gbn values.
  (define base 0)
  (define nextseq 0)
  (define N 10)
  (define pktlist (build-list N (lambda (value) (udpseg #f #f 0 (bytes)))))
  
  ;; Define our packets and buffers for sending data and receiving ACKs.
  (define datapkt (udpseg #f #f 0 (bytes)))
  (define ackpkt (udpseg #f #f 0 (bytes)))
  (define recvbytes (make-bytes mtusize))
  
  ;; Define the values needed to implement gbn here.
  (define dtgtimer never-evt)
  (define tmpval #f)
  
  (for ([i (in-naturals)]
        ;; When we reach the EOF object, the file is done.
        #:break (eof-object? (peek-bytes mtusize 0 infile)))
    ;; If the timer is expired, resend packets from base%N to nextseq-1%N.
    (if (sync/timeout 0 dtgtimer)
        ;; #t: Timer is expired. Resend pkts.
        (begin
          (for ([i (in-range (modulo base N) (modulo (- nextseq 1) N))])
            (displayln (format "RESENDING PACKET W/SEQNUM=~a" (udpseg-seqnum (list-ref pktlist i))))
            (udp-send return-sock (list-ref pktlist i)))
          (set! dtgtimer (alarm-evt (+ (current-inexact-milliseconds) 1000))))
        ;; #f: Timer is not on, or is running.
        (if (< nextseq (+ base N))
            ;; If we have sequence numbers to use, send packets.
            (begin
              ;; Build pkt, put it into the list, increment nextseq.
              (set! datapkt (build-pkt #f #f nextseq (trim-buffer filebuf (read-bytes! filebuf infile))))
              (set! pktlist (set!-list-item pktlist (modulo nextseq N) datapkt))
              (displayln (format "SENDING PACKET W/SEQNUM=~a" nextseq))
              (set! nextseq (+ 1 nextseq))
              (udp-send return-sock datapkt)
              (if (evt? (sync/timeout 0 dtgtimer))
                  ;; If we get an event, it means the timer was ready, which means it has expired/isn't running. So, set it.
                  (set! dtgtimer (alarm-evt (+ (current-inexact-milliseconds) 1000)))
                  ;; If we do not get an event, the timer was not ready, which means it is currently running. 
                  null))
            ;; If we are waiting on ACKs, listen for them.
            (begin
              ;; Check if there is a datagram in the pool. 
              (set! tmpval (sync/timeout 0 (udp-receive!-evt receive-sock recvbytes)))
              (cond [(list? tmpval) (begin ;; There was something in the datagram buffer. Parse it and see if we need to do anything more with it.
                                      (set! ackpkt (parse-datagram recvbytes)) 
                                      (cond [(and (udpseg-ack ackpkt) (>= (udpseg-seqnum ackpkt) base) (< (udpseg-seqnum ackpkt) (+ base N))) ;; If it is an ACK AND its seqnum is in the range we're expecting
                                             (begin
                                               (displayln (format "RECEIVED ACK FOR SEQNUM=~a" (udpseg-seqnum ackpkt)))
                                               ;; Set base forward
                                              (set! base (+ 1 (udpseg-seqnum ackpkt)))
                                               ;; Does this ACK cover all the packets we have sent so far?
                                               (if (= nextseq base)
                                                   ;; #t: Turn off the timer
                                                   (set! dtgtimer never-evt)
                                                   ;; #f: Set the timer for the remaining, unACKed packets
                                                   (set! dtgtimer (alarm-evt (+ (current-inexact-milliseconds) 1000)))))]))])))
        )
    ;; If we have additional sequence numbers from base to use
    
    )
  (displayln "EOF REACHED, ALL FILE CHUNKS SENT\nSENDING EOF PACKET...")
  (udp-send return-sock (build-pkt #f #t nextseq (bytes)))
  (for ([i (in-naturals)]
        #:break (begin
                  ;; Listen for a datagram
                  (set! tmpval (sync/timeout 1 (udp-receive!-evt receive-sock recvbytes)))
                  ;; If we got one, parse it, if not, keep listening.
                  (if (list? tmpval)
                      (set! ackpkt (parse-datagram recvbytes))
                      #f
                      )
                  ;; If the datagram was a list AND ACK=1 AND EOFILE=1
                  ;; then we send our own ACKEOF packet, and break. We only send it once
                  ;; due to infinite regression problems.
                  (if (and (list? tmpval) (udpseg-ack ackpkt) (udpseg-eofile ackpkt))
                      (begin
                        (set! datapkt (build-pkt #t #t 0 (bytes)))
                        (udp-send return-sock datapkt)
                        #t)
                      #f)))
    null)
  (displayln "ACKEOF RECEIVED, FILE TRANSFER COMPLETE"))
  ;;->is there a timer? (is timer not ready?)
  ;;when nextseq<base+N:
  ;;->send packet, seqnum=nextseq
  ;;->add pkt to packet array at seqnum%N
  ;;->nextseq++
  ;;when we get an ack:
  ;;->base=seqnum(ack)+1
  ;;->is there a timer?
  ;;-->if yes, restart it for rest of unACKd
  ;;-->if no, start one ^^
  ;;when timer expires:
  ;;->resend all packets from base%N to nextseq-1%N
  ;;->reset timer
  ;;when we reach eof:
  ;;->send eof pkt
  ;;->connection teardown

;;
;; Main routine
;;
;; The listening port is defined through listenport.
;;(trace alt-bit-send)
(let ((sock (udp-open-socket))
      (retsock (udp-open-socket))
      (bufstr (make-bytes 500)))
  (define listenport 5050)
  ;; Main listening port
  (udp-bind! sock #f listenport)
  ;; Prepare a client struct to record information about the incoming client
  (define udpconn (udp-client 0 0))
  
  ;; We don't care here how many bytes we recieved; only what ip and port they came from.
  (match-let-values (((_ ip port) (udp-receive! sock bufstr)))
                    (set-udp-client-ip! udpconn ip)
                    (set-udp-client-port! udpconn port))
  
  ;; Parse the datagram and do some pretty displaying
  (define pkt (parse-datagram bufstr))

  (displayln "REQUEST FROM CLIENT: ")
  (displayln (list "ACK:" (udpseg-ack pkt)))
  (displayln (list "EOF:" (udpseg-eofile pkt)))
  (displayln (list "SEQ:" (udpseg-seqnum pkt)))
  (displayln (list "DATA:" (udpseg-data pkt)))

  (define ackyn #f)
  ;; Extract the requested file from the data portion.
  (define reqfile (string->path (car (cdr (string-split (bytes->string/utf-8 (udpseg-data pkt))
                                                        "::")))))
  ;; Check if the file exists and is non-empty.
  (set! ackyn (and (file-exists? reqfile) (not (= 0 (file-size reqfile)))))

  ;; Connect the UDP socket to the client on the port they provided.
  (udp-connect! retsock
                (udp-client-ip udpconn)
                (get-ret-port (udpseg-data pkt)))

  ;; Send a datagram informing whether we have the file or not.
  (udp-send retsock (build-pkt ackyn (not ackyn) 0 (bytes)))
  ;; If we do have the file, transfer it according to a protocol.
  (if ackyn
      ;(alt-bit-send reqfile retsock sock)
      (gbn-send reqfile retsock sock)
      null
      ))
