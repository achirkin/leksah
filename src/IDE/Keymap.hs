--
-- | Module for handling keymaps,
-- | deals with gtk accelerators and double (emacs-like) keystrokes
--

module IDE.Keymap (
    Keymap(..)
) where

import qualified Data.Map as Map
import Text.ParserCombinators.Parsec
import qualified Text.ParserCombinators.Parsec.Token as P
import Text.ParserCombinators.Parsec.Language(emptyDef)
import Data.List (foldl',sort)
import Data.Char(toLower)

import IDE.Core.State
import Control.Monad (foldM)
import System.Log.Logger (infoM)
import Data.Text (Text)
import qualified Data.Text as T (toLower, unpack, pack)
import Control.Applicative ((<$>))
import IDE.Core.Types (KeyVal)
import GI.Gdk (keyvalFromName, ModifierType(..))

class Keymap alpha where
    parseKeymap         ::   FilePath -> IO alpha
    setKeymap           ::   alpha -> [ActionDescr IDERef] -> [ActionDescr IDERef]
    buildSpecialKeys    ::   alpha -> [ActionDescr IDERef] -> IO (SpecialKeyTable IDERef)


instance Keymap KeymapI where
    parseKeymap         =   parseKeymap'
    setKeymap           =   setKeymap'
    buildSpecialKeys    =   buildSpecialKeys'

--
-- | Loads and parses a keymap file
--

parseKeymap' :: FilePath -> IO KeymapI
parseKeymap' fn = do
    infoM "leksah" $ "Reading keymap from " ++ fn
    res <- parseFromFile keymapParser fn
    case res of
        Left pe -> throwIDE . T.pack $ "Error reading keymap file " ++ show fn ++ " " ++ show pe
        Right r -> return r

--
-- | Sets the accelerators is the action descriptions from the keymap
--
setKeymap' :: KeymapI -> [ActionDescr IDERef] -> [ActionDescr IDERef]
setKeymap' (KM keymap)  = map setAccel
    where setAccel act = case Map.lookup (name act) keymap of
                            Nothing -> act
                            Just [] -> act
                            Just keyList -> foldl' setAccelerator act keyList
          setAccelerator act (Just (Left acc),Nothing)      = act{accelerator= acc : accelerator act}
          setAccelerator act (Just (Left acc),Just expl)    = act{accelerator= acc : accelerator act,
                                                                tooltip= Just expl}
          setAccelerator act (_, Just expl)                 = act{tooltip= Just expl}
          setAccelerator act (_,_)                          = act

--
-- | Builds a special keymap for handling double keystroke accelerators
-- Unfortunately in the IO Monad because of keyvalFromName
--
buildSpecialKeys' :: KeymapI -> [ActionDescr IDERef] -> IO (SpecialKeyTable IDERef)
buildSpecialKeys' (KM keymap) actions = do
    pseudoTriples <- mapM build actions
    let map1 = Map.fromListWith (++) $concat pseudoTriples
    return (Map.map Map.fromList map1)
    where
    build :: ActionDescr IDERef -> IO [((KeyVal,[ModifierType]),[((KeyVal, [ModifierType]), ActionDescr IDERef)])]
    build act =
        case Map.lookup (name act) keymap of
            Nothing             ->  return []
            Just l              ->  foldM (build' act) [] l
    build' act list (Just (Right (a1,a2)),_)
                                =   do  a1p <- accParse a1
                                        a2p <- accParse a2
                                        return ((a1p,[(a2p,act)]): list)
    build' act list _           =   return list


-- ---------------------------------------------------------------------
-- Parsing
--

keymapStyle :: P.LanguageDef st
keymapStyle= emptyDef
                { P.commentStart   = "{-"
                , P.commentEnd     = "-}"
                , P.commentLine    = "--"
                , P.identStart     = alphaNum <|> oneOf "<>_"
                , P.identLetter    = alphaNum <|> oneOf "<>_"
                }
lexer = P.makeTokenParser keymapStyle
lexeme = P.lexeme lexer
identifier = T.pack <$> P.identifier lexer
symbol =  P.symbol lexer
whiteSpace = P.whiteSpace lexer
stringLiteral = T.pack <$> P.stringLiteral lexer

keymapParser :: CharParser () KeymapI
keymapParser = do
    whiteSpace
    ls <- many lineparser
    eof
    return (KM (Map.fromListWith (++) ls))

lineparser :: CharParser () (ActionString, [(Maybe (Either KeyString
                                (KeyString,KeyString)), Maybe Text)])
lineparser = do
    mb1 <- option Nothing (do
        keyDescr <- identifier
        mb2 <- option Nothing (do
            symbol "/"
            key <- identifier
            return (Just key))
        return (Just (keyDescr, mb2)))
    symbol "->"
    action <- identifier
    mbs <- option Nothing (do
        str <- stringLiteral
        return (Just str))
    return (case mb1 of
        Nothing -> (action,[(Nothing,mbs)])
        Just (keyDescr,mb2) ->
            case mb2 of
                Just keyDescr2 -> (action,[(Just (Right (keyDescr,keyDescr2)),mbs)])
                Nothing -> (action,[(Just (Left keyDescr),mbs)]))
    <?> "lineparser"

--------------------------------------------------
-- Have to write this until gtk_accelerator_parse gets bound in gtk2hs
--
accParse :: Text -> IO (KeyVal,[ModifierType])
accParse str = case parse accparser "accelerator" (T.unpack str) of
    Right (ks,mods) -> do
        key <- keyvalFromName $ T.toLower ks
        return (key,sort mods)
    Left e -> throwIDE . T.pack $ show e

accStyle :: P.LanguageDef st
accStyle= emptyDef{P.caseSensitive = False}

lexer2 = P.makeTokenParser accStyle
lexeme2 = P.lexeme lexer2
symbol2 =  P.symbol lexer2
identifier2 = T.pack <$> P.identifier lexer2
whiteSpace2 = P.whiteSpace lexer2

accparser :: GenParser Char () (Text,[ModifierType])
accparser = do
    whiteSpace2
    mods <- many modparser
    key <- identifier2
    return (key, mods)

modparser :: GenParser Char () ModifierType
modparser = do
    try $symbol2 "<shift>"
    return ModifierTypeShiftMask
    <|> do
    try $symbol2 "<control>"
    return ModifierTypeControlMask
    <|> do
    try $symbol2 "<ctrl>"
    return ModifierTypeControlMask
    <|> do
    try $symbol2 "<alt>"
    return ModifierTypeMod1Mask
    <|> do
    try $symbol2 "<super>"
    return ModifierTypeSuperMask
    <|> do
    try $symbol2 "<meta>"
    return ModifierTypeMetaMask
    <|> do
    try $symbol2 "<compose>"
    return ModifierTypeHyperMask
    <?>"modparser"

