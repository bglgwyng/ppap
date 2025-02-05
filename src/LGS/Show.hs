module LGS.Show where

import Control.Monad.Trans.Class
import Control.Monad.Trans.Except
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Writer.Strict
import Data.Functor.Identity
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import LGS.Make
import LGS.Util
import Y.Base
import Z.Algo.Function
import Z.Utils

modifyCSinRE :: (CharSet -> ExceptT ErrMsg Identity CharSet) -> (RegEx -> ExceptT ErrMsg Identity RegEx)
modifyCSinRE modify = go where
    go :: RegEx -> ExceptT ErrMsg Identity RegEx
    go (ReVar var) = pure (ReVar var)
    go ReZero = pure ReZero
    go (regex1 `ReUnion` regex2) = pure ReUnion <*> go regex1 <*> go regex2
    go (ReWord word) = pure (ReWord word)
    go (regex1 `ReConcat` regex2) = pure ReConcat <*> go regex1 <*> go regex2
    go (ReStar regex1) = pure ReStar <*> go regex1
    go (ReDagger regex1) = pure ReDagger <*> go regex1
    go (ReQuest regex1) = pure ReQuest <*> go regex1
    go (ReCharSet chs) = pure ReCharSet <*> modify chs

substituteCS :: CharSetEnv -> CharSet -> ExceptT ErrMsg Identity CharSet
substituteCS env = go where
    go :: CharSet -> ExceptT ErrMsg Identity CharSet
    go (CsVar var) = maybe (throwE ("`substituteCS\': couldn't find the variable ``$" ++ var ++ "\'\' in the environment `" ++ show env ++ "\'.")) return (Map.lookup var env)
    go (CsSingle ch) = pure (CsSingle ch)
    go (CsEnum ch1 ch2) = pure (CsEnum ch1 ch2)
    go (chs1 `CsUnion` chs2) = pure CsUnion <*> go chs1 <*> go chs2
    go (chs1 `CsDiff` chs2) = pure CsDiff <*> go chs1 <*> go chs2
    go CsUniv = pure CsUniv

substituteRE :: RegExEnv -> RegEx -> ExceptT ErrMsg Identity RegEx
substituteRE env = go where
    go :: RegEx -> ExceptT ErrMsg Identity RegEx
    go (ReVar var) = maybe (throwE ("`substituteRE\': couldn't find the variable ``$" ++ var ++ "\'\' in the environment `" ++ show env ++ "\'.")) return (Map.lookup var env)
    go ReZero = pure ReZero
    go (regex1 `ReUnion` regex2) = pure ReUnion <*> go regex1 <*> go regex2
    go (ReWord word) = pure (ReWord word)
    go (regex1 `ReConcat` regex2) = pure ReConcat <*> go regex1 <*> go regex2
    go (ReStar regex1) = pure ReStar <*> go regex1
    go (ReDagger regex1) = pure ReDagger <*> go regex1
    go (ReQuest regex1) = pure ReQuest <*> go regex1
    go (ReCharSet chs) = pure (ReCharSet chs)

overlap :: String -> String -> String
overlap str1 str2 = case (length str1, length str2) of
    (n1, n2) -> if n1 >= n2 then take (n1 - n2) str1 ++ str2 else str2

genLexer :: [XBlock] -> ExceptT ErrMsg Identity [String]
genLexer xblocks = do
    (_, chs_env) <- flip runStateT Map.empty $ sequence
        [ do
            env <- get
            chs' <- lift (substituteCS env chs)
            put (Map.insert var chs' env)
        | CsVDef var chs <- xblocks
        ]
    (_, re_env) <- flip runStateT Map.empty $ sequence
        [ do
            env <- get
            re' <- lift (substituteRE env re)
            put (Map.insert var re' env)
        | ReVDef var re <- xblocks
        ]
    theDFA <- fmap makeDFAfromREs $ sequence
        [ case right_ctx of
            NilRCtx -> do
                regex1' <- substituteRE re_env regex1
                regex1'' <- modifyCSinRE (substituteCS chs_env) regex1'
                return (regex1'', NilRCtx)
            PosRCtx regex2 -> do
                regex1' <- substituteRE re_env regex1
                regex1'' <- modifyCSinRE (substituteCS chs_env) regex1'
                regex2' <- substituteRE re_env regex2
                regex2'' <- modifyCSinRE (substituteCS chs_env) regex2'
                return (regex1'', PosRCtx regex2'')
            OddRCtx regex2 -> do
                regex1' <- substituteRE re_env regex1
                regex1'' <- modifyCSinRE (substituteCS chs_env) regex1'
                regex2' <- substituteRE re_env regex2
                regex2'' <- modifyCSinRE (substituteCS chs_env) regex2'
                return (regex1'', OddRCtx regex2'')
            NegRCtx regex2 -> do
                regex1' <- substituteRE re_env regex1
                regex1'' <- modifyCSinRE (substituteCS chs_env) regex1'
                regex2' <- substituteRE re_env regex2
                regex2'' <- modifyCSinRE (substituteCS chs_env) regex2'
                return (regex1'', NegRCtx regex2'')
        | XMatch (regex1, right_ctx) _ <- xblocks
        ]
    (token_type, lexer_name) <- case [ (token_type, lexer_name) | Target token_type lexer_name <- xblocks ] of
        [pair] -> return pair
        _ -> throwE "A target must exist unique."
    hshead <- case [ hscode | HsHead hscode <- xblocks ] of
        [hscode] -> return hscode
        _ -> throwE "A hshead must exist unique."
    hstail <- case [ hscode | HsTail hscode <- xblocks ] of
        [hscode] -> return hscode
        _ -> throwE "A hstail must exist unique."
    ((), x_out) <- runWriterT $ do
        let _this = lexer_name ++ "_this"
            theRegexTable = generateRegexTable theDFA
            theMaxLen = length (show (maybe 0 fst (Set.maxView (Map.keysSet theRegexTable))))
            tellLine string_stream = tell [string_stream "\n"]
        tellLine (ppunc "\n" (map strstr hshead))
        tellLine (strstr "import qualified Control.Monad.Trans.State.Strict as XState")
        tellLine (strstr "import qualified Data.Functor.Identity as XIdentity")
        tellLine (strstr "import qualified Data.Map.Strict as XMap")
        tellLine (strstr "import qualified Data.Set as XSet")
        tellLine (ppunc "\n" (strstr "" : map strstr hstail))
        if null hstail then return () else tellLine (strstr "")
        tellLine (strstr "-- the following codes are generated by LGS.")
        if getInitialQOfDFA theDFA `Set.member` Map.keysSet (getFinalQsOfDFA theDFA) then tellLine (strstr "-- Warning: The empty string is acceptable!") else return ()
        tellLine (strstr "")
        tellLine (strstr "data DFA")
        tellLine (strstr "    = DFA")
        tellLine (strstr "        { getInitialQOfDFA :: Int")
        tellLine (strstr "        , getFinalQsOfDFA :: XMap.Map Int Int")
        tellLine (strstr "        , getTransitionsOfDFA :: XMap.Map (Int, Char) Int")
        tellLine (strstr "        , getMarkedQsOfDFA :: XMap.Map Int (Bool, XSet.Set Int)")
        tellLine (strstr "        , getPseudoFinalsOfDFA :: XSet.Set Int")
        tellLine (strstr "        }")
        tellLine (strstr "    deriving ()")
        tellLine (strstr "")
        tellLine (strstr lexer_name . strstr " :: String -> Either (Int, Int) [" . strstr token_type . strstr "]")
        tellLine (strstr lexer_name . strstr " = " . strstr _this . strstr " . addLoc 1 1 where")
        sequence
            [ tellLine (strstr "    -- " . strstr (overlap (replicate theMaxLen ' ') (show q)) . strstr ": " . pprint 0 re)
            | (q, re) <- Map.toAscList theRegexTable
            ]
        tellLine (strstr "    theDFA :: DFA")
        tellLine (strstr "    theDFA = DFA")
        tellLine (strstr "        { getInitialQOfDFA = " . shows (getInitialQOfDFA theDFA))
        tellLine (strstr "        , getFinalQsOfDFA = XMap.fromAscList [" . ppunc ", " [ strstr "(" . shows q . strstr ", " . shows p . strstr ")" | (q, p) <- Map.toAscList (getFinalQsOfDFA theDFA) ] . strstr "]")
        tellLine (strstr "        , getTransitionsOfDFA = XMap.fromAscList " . plist 12 [ ppunc ", " [ strstr "((" . shows q . strstr ", " . shows ch . strstr "), " . shows p . strstr ")" | ((q, ch), p) <- deltas ] | deltas <- splitUnless (\x1 -> \x2 -> fst (fst x1) == fst (fst x2)) (Map.toAscList (getTransitionsOfDFA theDFA)) ])
        tellLine (strstr "        , getMarkedQsOfDFA = XMap.fromAscList " . plist 12 [ strstr "(" . shows q . strstr ", (" . shows b . strstr ", XSet.fromAscList [" . ppunc ", " [ shows p | p <- Set.toAscList ps ] . strstr "]))" | (q, (b, ps)) <- Map.toAscList (getMarkedQsOfDFA theDFA) ])
        tellLine (strstr "        , getPseudoFinalsOfDFA = XSet.fromAscList [" . ppunc ", " [ shows q | q <- Set.toAscList (getPseudoFinalsOfDFA theDFA) ] . strstr "]")
        tellLine (strstr "        }")
        tellLine (strstr "    runDFA :: DFA -> [((Int, Int), Char)] -> Either (Int, Int) ((Maybe Int, [((Int, Int), Char)]), [((Int, Int), Char)])")
        tellLine (strstr "    runDFA (DFA q0 qfs deltas markeds pseudo_finals) = if XSet.null pseudo_finals then Right . XIdentity.runIdentity . runFast else runSlow where")
        tellLine (strstr "        loop1 :: Int -> [((Int, Int), Char)] -> [((Int, Int), Char)] -> XState.StateT (Maybe Int, [((Int, Int), Char)]) XIdentity.Identity [((Int, Int), Char)]")
        tellLine (strstr "        loop1 q buffer [] = return buffer")
        tellLine (strstr "        loop1 q buffer (ch : str) = do")
        tellLine (strstr "            (latest, accepted) <- XState.get")
        tellLine (strstr "            case XMap.lookup (q, snd ch) deltas of")
        tellLine (strstr "                Nothing -> return (buffer ++ [ch] ++ str)")
        tellLine (strstr "                Just p -> case XMap.lookup p qfs of")
        tellLine (strstr "                    Nothing -> loop1 p (buffer ++ [ch]) str")
        tellLine (strstr "                    latest' -> do")
        tellLine (strstr "                        XState.put (latest', accepted ++ buffer ++ [ch])")
        tellLine (strstr "                        loop1 p [] str")
        tellLine (strstr "        loop2 :: XSet.Set Int -> Int -> [((Int, Int), Char)] -> [((Int, Int), Char)] -> XState.StateT [((Int, Int), Char)] XIdentity.Identity [((Int, Int), Char)]")
        tellLine (strstr "        loop2 qs q [] buffer = return buffer")
        tellLine (strstr "        loop2 qs q (ch : str) buffer = do")
        tellLine (strstr "            case XMap.lookup (q, snd ch) deltas of")
        tellLine (strstr "                Nothing -> return (buffer ++ [ch] ++ str)")
        tellLine (strstr "                Just p -> case p `XSet.member` qs of")
        tellLine (strstr "                    False -> loop2 qs p str (buffer ++ [ch])")
        tellLine (strstr "                    True -> do")
        tellLine (strstr "                        accepted <- XState.get")
        tellLine (strstr "                        XState.put (accepted ++ buffer ++ [ch])")
        tellLine (strstr "                        loop2 qs p str []")
        tellLine (strstr "        loop3 :: XSet.Set Int -> Int -> [((Int, Int), Char)] -> [((Int, Int), Char)] -> XState.StateT [((Int, Int), Char)] XIdentity.Identity [((Int, Int), Char)]")
        tellLine (strstr "        loop3 qs q [] buffer = return buffer")
        tellLine (strstr "        loop3 qs q (ch : str) buffer = do")
        tellLine (strstr "            case XMap.lookup (q, snd ch) deltas of")
        tellLine (strstr "                Nothing -> return (buffer ++ [ch] ++ str)")
        tellLine (strstr "                Just p -> case p `XSet.member` qs of")
        tellLine (strstr "                    False -> loop3 qs p str (buffer ++ [ch])")
        tellLine (strstr "                    True -> do")
        tellLine (strstr "                        accepted <- XState.get")
        tellLine (strstr "                        XState.put (accepted ++ buffer ++ [ch])")
        tellLine (strstr "                        return str")
        tellLine (strstr "        runFast :: [((Int, Int), Char)] -> XIdentity.Identity ((Maybe Int, [((Int, Int), Char)]), [((Int, Int), Char)])")
        tellLine (strstr "        runFast input = do")
        tellLine (strstr "            (rest, (latest, accepted)) <- XState.runStateT (loop1 q0 [] input) (Nothing, [])")
        tellLine (strstr "            case latest >>= flip XMap.lookup markeds of")
        tellLine (strstr "                Nothing -> return ((latest, accepted), rest)")
        tellLine (strstr "                Just (True, qs) -> do")
        tellLine (strstr "                    (rest', accepted') <- XState.runStateT (loop2 qs q0 accepted []) []")
        tellLine (strstr "                    return ((latest, accepted'), rest' ++ rest)")
        tellLine (strstr "                Just (False, qs) -> do")
        tellLine (strstr "                    (rest', accepted') <- XState.runStateT (loop3 qs q0 accepted []) []")
        tellLine (strstr "                    return ((latest, accepted'), rest' ++ rest)")
        tellLine (strstr "        runSlow :: [((Int, Int), Char)] -> Either (Int, Int) ((Maybe Int, [((Int, Int), Char)]), [((Int, Int), Char)])")
        tellLine (strstr "        runSlow = undefined")
        tellLine (strstr "    addLoc :: Int -> Int -> String -> [((Int, Int), Char)]")
        tellLine (strstr "    addLoc _ _ [] = []")
        tellLine (strstr "    addLoc row col (ch : chs) = if ch == \'\\n\' then ((row, col), ch) : addLoc (row + 1) 1 chs else ((row, col), ch) : addLoc row (col + 1) chs")
        tellLine (strstr "    " . strstr _this . strstr " :: [((Int, Int), Char)] -> Either (Int, Int) [" . strstr token_type . strstr "]")
        tellLine (strstr "    " . strstr _this . strstr " [] = return []")
        tellLine (strstr "    " . strstr _this . strstr " str0 = do")
        tellLine (strstr "        let return_one my_token = return [my_token]")
        tellLine (strstr "        dfa_output <- runDFA theDFA str0")
        tellLine (strstr "        (str1, piece) <- case dfa_output of")
        tellLine (strstr "            ((_, []), _) -> Left (fst (head str0))")
        tellLine (strstr "            ((Just label, accepted), rest) -> return (rest, ((label, map snd accepted), (fst (head accepted), fst (head (reverse accepted)))))")
        tellLine (strstr "            _ -> Left (fst (head str0))")
        tellLine (strstr "        tokens1 <- case piece of")
        let destructors = [ destructor | XMatch _ destructor <- xblocks ]
        sequence
            [ case destructor of
                Just [hscode] -> do
                    tellLine (strstr "            ((" . shows label . strstr ", this), ((row1, col1), (row2, col2))) -> return_one (" . strstr hscode . strstr ")")
                    return ()
                Just (hscode : hscodes) -> do
                    tellLine (strstr "            ((" . shows label . strstr ", this), ((row1, col1), (row2, col2))) -> return_one $ " . strstr hscode)
                    tellLine (ppunc "\n" [ strstr "            " . strstr str | str <- hscodes ])
                    return ()
                _ -> do
                    tellLine (strstr "            ((" . shows label . strstr ", this), ((row1, col1), (row2, col2))) -> return []")
                    return ()
            | (label, destructor) <- zip [1, 2 .. length destructors] destructors 
            ]
        tellLine (strstr "        tokens2 <- " . strstr _this . strstr " str1")
        tellLine (strstr "        return (tokens1 ++ tokens2)")
        return ()
    return x_out
