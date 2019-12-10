{-# LANGUAGE ForeignFunctionInterface #-}

module Chainweb.Pact.Backend.SQLite.V2 where

import Database.SQLite3.Bindings.Types

import Foreign
import Foreign.C

foreign import ccall "sqlite3_open_v2"
    c_sqlite3_open_v2 :: CString -> Ptr (Ptr CDatabase) -> CInt -> CString -> IO CError

foreign import ccall "sqlite3_close_v2"
    c_sqlite3_close_v2 :: Ptr CDatabase -> IO CError

foreign import ccall "sqlite3_wal_checkpoint_v2"
    c_sqlite3_wal_checkpoint_v2
        :: Ptr CDatabase
        -> CString
        -> CInt
        -> Ptr CInt
        -> Ptr CInt
        -> IO CError
