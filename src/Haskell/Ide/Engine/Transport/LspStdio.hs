{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Haskell.Ide.Engine.Transport.LspStdio
  (
    lspStdioTransport
  ) where

import           Control.Concurrent
import           Control.Concurrent.STM.TChan
import qualified Control.Exception as E
import           Control.Lens ( (^.) )
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.STM
import           Control.Monad.Trans.State.Lazy
import qualified Data.Aeson as J
import           Data.Aeson ( (.=) )
import qualified Data.Aeson.Types as J
import           Data.Algorithm.DiffOutput
import           Data.Default
import           Data.Either
import           Data.Monoid ( (<>) )
import           Data.Foldable
import qualified Data.HashMap.Strict as H
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Vector as V
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.SemanticTypes
import           Haskell.Ide.Engine.Types
import qualified Haskell.Ide.HaRePlugin as HaRe
import qualified Haskell.Ide.GhcModPlugin as GhcMod
import qualified Haskell.Ide.ApplyRefactPlugin as ApplyRefact
import qualified Language.Haskell.LSP.Control  as CTRL
import qualified Language.Haskell.LSP.Core     as Core
import           Language.Haskell.LSP.Diagnostics
import           Language.Haskell.LSP.Messages
import qualified Language.Haskell.LSP.TH.DataTypesJSON as J
import qualified Language.Haskell.LSP.Utility  as U
import           System.Directory
import           System.Exit
import           System.FilePath
import qualified System.Log.Logger as L
import           Text.Parsec
-- import qualified Yi.Rope as Yi

-- ---------------------------------------------------------------------
{-# ANN module ("hlint: ignore Eta reduce" :: String) #-}
{-# ANN module ("hlint: ignore Redundant do" :: String) #-}

-- ---------------------------------------------------------------------

lspStdioTransport :: IO () -> TChan PluginRequest -> FilePath -> IO ()
lspStdioTransport hieDispatcherProc cin origDir = do
  run hieDispatcherProc cin origDir >>= \case
    0 -> exitSuccess
    c -> exitWith . ExitFailure $ c


-- ---------------------------------------------------------------------

run :: IO () -> TChan PluginRequest -> FilePath -> IO Int
run dispatcherProc cin origDir = flip E.catches handlers $ do

  rin  <- atomically newTChan :: IO (TChan ReactorInput)
  let
    dp lf = do
      _rpid <- forkIO $ reactor lf def cin rin
      dispatcherProc
      return Nothing

  flip E.finally finalProc $ do
    tmpDir <- getTemporaryDirectory
    let logDir = tmpDir </> "hie-logs"
    createDirectoryIfMissing True logDir
    let dirStr = map (\c -> if c == pathSeparator then '-' else c) origDir
    -- (logFileName,handle) <- openTempFile logDir "hie-lsp.log"
    -- hClose handle -- Logger will open the file again
    let logFileName = logDir </> (dirStr ++ "-hie.log")
    Core.setupLogger logFileName L.DEBUG
    CTRL.run dp (hieHandlers rin) hieOptions

  where
    handlers = [ E.Handler ioExcept
               , E.Handler someExcept
               ]
    finalProc = L.removeAllHandlers
    ioExcept   (e :: E.IOException)       = print e >> return 1
    someExcept (e :: E.SomeException)     = print e >> return 1

-- ---------------------------------------------------------------------

data ReactorInput
  = HandlerRequest Core.LspFuncs Core.OutMessage
      -- ^ injected into the reactor input by each of the individual callback handlers

data ReactorState =
  ReactorState
    { lspReqId           :: !J.LspId
    }

instance Default ReactorState where
  def = ReactorState (J.IdInt 0)

-- ---------------------------------------------------------------------

-- | The monad used in the reactor
type R a = StateT ReactorState IO a

-- ---------------------------------------------------------------------
-- reactor monad functions
-- ---------------------------------------------------------------------


reactorSend :: (J.ToJSON a, MonadIO m) => Core.LspFuncs -> a -> m ()
reactorSend lf msg = liftIO $ Core.sendFunc lf msg

-- ---------------------------------------------------------------------

reactorSend' :: MonadIO m => Core.LspFuncs -> (Core.SendFunc -> IO ()) -> m ()
reactorSend' lf f = liftIO $ f (Core.sendFunc lf)

  -- msf <- gets sender
  -- case msf of
  --   Nothing -> error "reactorSend': send function not initialised yet"
  --   Just sf -> liftIO $ f sf

-- ---------------------------------------------------------------------

publishDiagnostics :: MonadIO m => Core.LspFuncs -> J.Uri -> Maybe J.TextDocumentVersion -> DiagnosticsBySource -> m ()
publishDiagnostics lf uri' mv diags =
    liftIO $ (Core.publishDiagnosticsFunc lf) uri' mv diags


-- ---------------------------------------------------------------------

nextLspReqId :: R J.LspId
nextLspReqId = do
  s <- get
  let i@(J.IdInt r) = lspReqId s
  put s { lspReqId = J.IdInt (r + 1) }
  return i

-- ---------------------------------------------------------------------

sendErrorResponse :: MonadIO m => Core.LspFuncs -> J.LspId -> J.ErrorCode -> T.Text -> m ()
sendErrorResponse lf origId err msg
  = reactorSend' lf (\sf -> Core.sendErrorResponseS sf (J.responseId origId) err msg)

sendErrorLog :: MonadIO m => Core.LspFuncs -> T.Text -> m ()
sendErrorLog lf msg = reactorSend' lf (\sf -> Core.sendErrorLogS  sf msg)

-- sendErrorShow :: String -> R ()
-- sendErrorShow msg = reactorSend' (\sf -> Core.sendErrorShowS sf msg)

-- ---------------------------------------------------------------------
-- reactor monad functions end
-- ---------------------------------------------------------------------


-- | The single point that all events flow through, allowing management of state
-- to stitch replies and requests together from the two asynchronous sides: lsp
-- server and hie dispatcher
reactor :: Core.LspFuncs -> ReactorState -> TChan PluginRequest -> TChan ReactorInput -> IO ()
reactor lf st cin inp = do
  flip evalStateT st $ forever $ do
    inval <- liftIO $ atomically $ readTChan inp
    case inval of
      HandlerRequest _lf (Core.RspFromClient rm) -> do
        liftIO $ U.logs $ "reactor:got RspFromClient:" ++ show rm

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) (Core.NotInitialized _notification) -> do
        liftIO $ U.logm $ "****** reactor: processing Initialized Notification"
        -- Server is ready, register any specific capabilities we need

         {-
         Example:
         {
                 "method": "client/registerCapability",
                 "params": {
                         "registrations": [
                                 {
                                         "id": "79eee87c-c409-4664-8102-e03263673f6f",
                                         "method": "textDocument/willSaveWaitUntil",
                                         "registerOptions": {
                                                 "documentSelector": [
                                                         { "language": "javascript" }
                                                 ]
                                         }
                                 }
                         ]
                 }
         }
        -}
        let
          options = J.object ["documentSelector" .= J.object [ "language" .= J.String "haskell"]]
          registration = J.Registration "hare:demote" "workspace/executeCommand" (Just options)
        let registrations = J.RegistrationParams (J.List [registration])
        rid <- nextLspReqId

        reactorSend lf $ fmServerRegisterCapabilityRequest rid registrations

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) n@(Core.NotDidOpenTextDocument notification) -> do
        liftIO $ U.logm $ "****** reactor: processing NotDidOpenTextDocument"
        let
            doc = notification ^. J.params . J.textDocument . J.uri
        requestDiagnostics lf cin doc

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) n@(Core.NotDidSaveTextDocument notification) -> do
        liftIO $ U.logm "****** reactor: processing NotDidSaveTextDocument"
        let
            doc = notification ^. J.params . J.textDocument . J.uri
        requestDiagnostics lf cin doc

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) (Core.NotDidChangeTextDocument _notification) -> do
        liftIO $ U.logm "****** reactor: NOT processing NotDidChangeTextDocument"

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) r@(Core.ReqRename req) -> do
        liftIO $ U.logs $ "reactor:got RenameRequest:" ++ show req
        let params = req ^. J.params
            doc = params ^. J.textDocument
            uri = doc ^. J.uri
            pos = params ^. J.position
            newName  = params ^. J.newName
        let hreq = PReq callback $ HaRe.renameCmd' (TextDocumentPositionParams doc pos) newName
            callback res = hieResponseHelper lf (req ^. J.id) res $ \we -> do
                let rspMsg = Core.makeResponseMessage (J.responseId $ req ^. J.id ) we
                reactorSend lf rspMsg
        liftIO $ atomically $ writeTChan cin hreq


      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) r@(Core.ReqHover req) -> do
        liftIO $ U.logs $ "reactor:got HoverRequest:" ++ show req
        let params = req ^. J.params
            pos = params ^. J.position
            doc = params ^. J.textDocument . J.uri
        let hreq = PReq callback $ GhcMod.typeCmd' True doc pos
            callback res = hieResponseHelper lf (req ^. J.id) res $ \(TypeInfo mtis) -> do
                let
                  ht = case mtis of
                    []  -> J.Hover (J.List []) Nothing
                    tis -> J.Hover (J.List ms) (Just range)
                      where
                        ms = map (\ti -> J.MarkedString "haskell" (trText ti)) tis
                        tr = head tis
                        range = J.Range (trStart tr) (trEnd tr)
                  rspMsg = Core.makeResponseMessage ( J.responseId $ req ^. J.id ) ht
                reactorSend lf rspMsg
        liftIO $ atomically $ writeTChan cin hreq

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) (Core.ReqCodeAction req) -> do
        liftIO $ U.logs $ "reactor:got CodeActionRequest:" ++ show req
        let params = req ^. J.params
            doc = params ^. J.textDocument
            (J.List diags) = params ^. J.context . J.diagnostics

        let
          makeCommand (J.Diagnostic (J.Range start _) _s _c (Just "hlint") m  ) = [J.Command title cmd cmdparams]
            where
              title :: T.Text
              title = "Apply hint:" <> (head (T.lines m))
              -- NOTE: the cmd needs to be registered via the InitializeResponse message. See hieOptions above
              cmd = "applyrefact:applyOne"
              -- need 'file' and 'start_pos'
              args = J.Array$ V.fromList
                      [ J.object ["file" .= J.object ["textDocument" .= doc]]
                      , J.object ["start_pos" .= J.object ["position" .= start]]
                      ]
              cmdparams = Just args
          makeCommand (J.Diagnostic _r _s _c _source _m  ) = []
          -- TODO: make context specific commands for all sorts of things, such as refactorings
        let body = concatMap makeCommand diags
        let rspMsg = Core.makeResponseMessage (J.responseId $ req ^. J.id ) body
        reactorSend lf rspMsg

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) r@(Core.ReqExecuteCommand req) -> do
        liftIO $ U.logs $ "reactor:got ExecuteCommandRequest, skipping:" -- ++ show req
        -- cwd <- liftIO getCurrentDirectory
        -- liftIO $ U.logs $ "reactor:cwd:" ++ cwd
        let params = req ^. J.params
            command = params ^. J.command
            margs = params ^. J.arguments


        return ()
        -- liftIO $ U.logs $ "reactor:ExecuteCommandRequest:margs=" ++ show margs
        -- cmdparams <- case margs of
        --       Nothing -> return []
        --       Just (J.List os) -> do
        --         let (lts,rts) = partitionEithers $ map convertParam os
        --         -- TODO:AZ: return an error if any parse errors found.
        --         unless (null lts) $
        --           liftIO $ U.logs $ "\n\n****reactor:ExecuteCommandRequest:error converting params=" ++ show lts ++ "\n\n"
        --         return rts

        --rid <- nextReqId
        -- let (plugin,cmd) = break (==':') (T.unpack command)
        --let hreq = CReq (T.pack plugin) rid (IdeRequest (T.pack $ tail cmd) (Map.fromList cmdparams)) cout
        -- liftIO $ atomically $ writeTChan cin hreq
        -- keepOriginal rid (r, Nothing)

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) (Core.ReqCompletion req) -> do
        liftIO $ U.logs $ "reactor:got CompletionRequest:" ++ show req
        let params = req ^. J.params
            doc = params ^. J.textDocument
            J.Position l c = params ^. J.position
        -- rid <- nextReqId
        -- let hreq = CReq "ghcmod" rid (IdeRequest "type" (Map.fromList
        --                                             [("file",     ParamFileP (T.pack fileName))
        --                                             ,("start_pos",ParamPosP (toPos (l+1,c+1)))
        --                                             ])) cout
        -- liftIO $ atomically $ writeTChan cin hreq
        -- keepOriginal rid r
        liftIO $ U.logs $ "****reactor:ReqCompletion:not immplemented=" ++ show (doc,l,c)

        let cr = J.Completions (J.List []) -- ( [] :: [J.CompletionListType])
        let rspMsg = Core.makeResponseMessage (J.responseId $ req ^. J.id ) cr
        reactorSend lf rspMsg

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) (Core.ReqDocumentHighlights req) -> do
        liftIO $ U.logs $ "reactor:got DocumentHighlightsRequest:" ++ show req
        let params = req ^. J.params
            doc = params ^. J.textDocument ^. J.uri
            pos = params ^. J.position
        -- rid <- nextReqId
        -- let hreq = CReq "ghcmod" rid (IdeRequest "type" (Map.fromList
        --                                             [("file",     ParamFileP (T.pack fileName))
        --                                             ,("start_pos",ParamPosP (toPos (l+1,c+1)))
        --                                             ])) cout
        -- liftIO $ atomically $ writeTChan cin hreq
        -- keepOriginal rid r
        liftIO $ U.logs $ "****reactor:ReqDocumentHighlights:not immplemented=" ++ show (doc,pos)

        let cr = J.List  ([] :: [J.DocumentHighlight])
        let rspMsg = Core.makeResponseMessage (J.responseId $ req ^. J.id ) cr
        reactorSend lf rspMsg

      -- -------------------------------

      HandlerRequest (Core.LspFuncs _c _sf _vf _pd) om -> do
        liftIO $ U.logs $ "reactor:got HandlerRequest:" ++ show om

-- ---------------------------------------------------------------------

requestDiagnostics :: Core.LspFuncs -> TChan PluginRequest -> J.Uri -> R ()
requestDiagnostics lf cin file = do
  let sendOne pid (uri',ds) =
        publishDiagnostics lf uri' Nothing (Map.fromList [(Just pid,ds)])
      mkDiag (f,ds) = do
        af <- liftIO $ makeAbsolute f
        return (J.filePathToUri af, ds)
      sendEmpty = publishDiagnostics lf file Nothing (Map.fromList [(Just "ghcmod",[])])
  -- get hlint diagnostics
  let reql = PReq callbackl $ ApplyRefact.lintCmd' file
      callbackl (IdeResponseFail  err) = liftIO $ U.logs $ "got err" ++ show err
      callbackl (IdeResponseError err) = liftIO $ U.logs $ "got err" ++ show err
      callbackl (IdeResponseOk  diags) =
        case diags of
          (PublishDiagnosticsParams fp (List ds)) -> sendOne "applyrefact" (fp, ds)
  liftIO $ atomically $ writeTChan cin reql

  -- get GHC diagnostics
  let reqg = PReq callbackg $ GhcMod.checkCmd' file
      callbackg (IdeResponseFail  err) = liftIO $ U.logs $ "got err" ++ show err
      callbackg (IdeResponseError err) = liftIO $ U.logs $ "got err" ++ show err
      callbackg (IdeResponseOk    str) = do
        let pd = parseGhcDiagnostics str
        ds <- mapM mkDiag $ Map.toList $ Map.fromListWith (++) pd
        case ds of
          [] -> sendEmpty
          _ -> mapM_ (sendOne "ghcmod") ds
  liftIO $ atomically $ writeTChan cin reqg

-- ---------------------------------------------------------------------

convertParam :: J.Value -> Either String (ParamId, ParamValP)
convertParam (J.Object hm) = case H.toList hm of
  [(k,v)] -> case (J.fromJSON v) :: J.Result LspParam of
             J.Success pv -> Right (k, lspParam2ParamValP pv)
             J.Error errStr -> Left $ "convertParam: could not decode parameter value for "
                               ++ show k ++ ", err=" ++ errStr
  _       -> Left $ "convertParam: expecting a single key/value, got:" ++ show hm
convertParam v = Left $ "convertParam: expecting Object, got:" ++ show v

lspParam2ParamValP :: LspParam -> ParamValP
lspParam2ParamValP (LspTextDocument (TextDocumentIdentifier u)) = ParamFileP u
lspParam2ParamValP (LspPosition     p)                = ParamPosP p
lspParam2ParamValP (LspRange        (Range from _to)) = ParamPosP from
lspParam2ParamValP (LspText         txt             ) = ParamTextP txt

data LspParam
  = LspTextDocument TextDocumentIdentifier
  | LspPosition     Position
  | LspRange        Range
  | LspText         T.Text
  deriving (Read,Show,Eq)

instance J.FromJSON LspParam where
  parseJSON (J.Object hm) =
    case H.toList hm of
      [("textDocument",v)] -> LspTextDocument <$> J.parseJSON v
      [("position",v)]     -> LspPosition     <$> J.parseJSON v
      [("range-pos",v)]    -> LspRange        <$> J.parseJSON v
      [("text",v)]         -> LspText         <$> J.parseJSON v
      _ -> fail $ "FromJSON.LspParam got:" ++ show hm
  parseJSON _ = mempty

-- ---------------------------------------------------------------------

-- | Manage the boilerplate for passing on any errors found in the IdeResponse
hieResponseHelper :: forall m a t. (MonadIO m) => Core.LspFuncs -> J.LspId -> IdeResponse t -> (t -> m ()) -> m ()
hieResponseHelper lf lid res action =
  case res of
    IdeResponseFail  err -> sendErrorResponse lf lid J.InternalError (T.pack $ show err)
    IdeResponseError err -> sendErrorResponse lf lid J.InternalError (T.pack $ show err)
    IdeResponseOk r -> action r

-- ---------------------------------------------------------------------

hieOptions :: Core.Options
hieOptions = def { Core.textDocumentSync = Just J.TdSyncIncremental
                 , Core.completionProvider = Just (J.CompletionOptions (Just True) Nothing)
                 , Core.executeCommandProvider = Just (J.ExecuteCommandOptions (J.List ["applyrefact:applyOne","hare:demote"]))
                 }


hieHandlers :: TChan ReactorInput -> Core.Handlers
hieHandlers rin
  = def { Core.initializedHandler                       = Just $ passHandler rin Core.NotInitialized
        , Core.renameHandler                            = Just $ passHandler rin Core.ReqRename
        , Core.hoverHandler                             = Just $ passHandler rin Core.ReqHover
        , Core.didOpenTextDocumentNotificationHandler   = Just $ passHandler rin Core.NotDidOpenTextDocument
        , Core.didSaveTextDocumentNotificationHandler   = Just $ passHandler rin Core.NotDidSaveTextDocument
        , Core.didChangeTextDocumentNotificationHandler = Just $ passHandler rin Core.NotDidChangeTextDocument
        , Core.didCloseTextDocumentNotificationHandler  = Just $ passHandler rin Core.NotDidCloseTextDocument
        , Core.cancelNotificationHandler                = Just $ passHandler rin Core.NotCancelRequest
        , Core.responseHandler                          = Just $ responseHandlerCb rin
        , Core.codeActionHandler                        = Just $ passHandler rin Core.ReqCodeAction
        , Core.executeCommandHandler                    = Just $ passHandler rin Core.ReqExecuteCommand
        , Core.completionHandler                        = Just $ passHandler rin Core.ReqCompletion
        , Core.completionResolveHandler                 = Just $ passHandler rin Core.ReqCompletionItemResolve
        , Core.documentHighlightHandler                 = Just $ passHandler rin Core.ReqDocumentHighlights
        }

-- ---------------------------------------------------------------------

passHandler :: TChan ReactorInput -> (a -> Core.OutMessage) -> Core.Handler a
passHandler rin c lf notification = do
  atomically $ writeTChan rin (HandlerRequest lf (c notification))

-- ---------------------------------------------------------------------

responseHandlerCb :: TChan ReactorInput -> Core.Handler J.BareResponseMessage
responseHandlerCb _rin _lf resp = do
  U.logs $ "******** got ResponseMessage, ignoring:" ++ show resp

-- ---------------------------------------------------------------------

{-

Turn

[Change (LineRange {lrNumbers = (3,4), lrContents = ["foo :: Int","foo = 5"]})
        (LineRange {lrNumbers = (3,4), lrContents = ["foo1 :: Int","foo1 = 5"]})]

-- | Diff Operation  representing changes to apply
data DiffOperation a = Deletion a LineNo
            | Addition a LineNo
            | Change a a
            deriving (Show,Read,Eq,Ord)

into

interface TextEdit {
    /**
     * The range of the text document to be manipulated. To insert
     * text into a document create a range where start === end.
     */
    range: Range;

    /**
     * The string to be inserted. For delete operations use an
     * empty string.
     */
    newText: string;
}


data TextEdit =
  TextEdit
    { rangeTextEdit   :: Range
    , newTextTextEdit :: String
    } deriving (Show,Read,Eq)

-}
-- ---------------------------------------------------------------------
-- parsec parser for GHC error messages

type P = Parsec String ()

parseGhcDiagnostics :: T.Text -> [(FilePath,[J.Diagnostic])]
parseGhcDiagnostics str =
  case parse diagnostics "inp" (T.unpack str) of
    Left err -> error $ "parseGhcDiagnostics: got error" ++ show err
    Right ds -> ds

diagnostics :: P [(FilePath, [J.Diagnostic])]
diagnostics = (sepEndBy diagnostic (char '\n')) <* eof

diagnostic :: P (FilePath,[J.Diagnostic])
diagnostic = do
  fname <- many1 (noneOf ":")
  _ <- char ':'
  l <- number
  _ <- char ':'
  c <- number
  _ <- char ':'
  severity <- optionSeverity
  msglines <- sepEndBy (many1 (noneOf "\n\0")) (char '\0')
  let pos = (J.Position (l-1) (c-1))
  -- AZ:TODO: consider setting pprCols dflag value in the call, for better format on vscode
  return (fname,[J.Diagnostic (J.Range pos pos) (Just severity) Nothing (Just "ghcmod") (T.pack $ unlines msglines)] )

optionSeverity :: P J.DiagnosticSeverity
optionSeverity =
  (string "Warning:" >> return J.DsWarning)
  <|> (string "Error:" >> return J.DsError)
  <|> return J.DsError

number :: P Int
number = do
  s <- many1 digit
  return $ read s

-- ---------------------------------------------------------------------

