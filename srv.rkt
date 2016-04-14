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
  (define resendpkt #f)
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
    ;; If the result of the sync is a list, we have received something into the socket.
    ;; In that case, we don't need to resend the last packet.
    (set! resendpkt (begin
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
    (if resendpkt
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
      (alt-bit-send reqfile retsock sock)
      null
      ))
