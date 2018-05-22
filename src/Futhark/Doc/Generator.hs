{-# LANGUAGE OverloadedStrings #-}
module Futhark.Doc.Generator (renderFiles) where

import Control.Arrow ((***))
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Writer
import Data.List (sortBy, intersperse, inits, tails, isPrefixOf, find)
import Data.Char (isSpace)
import Data.Loc
import Data.Maybe
import Data.Ord
import qualified Data.Map as M
import qualified Data.Set as S
import System.FilePath (splitPath, (-<.>), (<.>), makeRelative)
import Text.Blaze.Html5 (AttributeValue, Html, (!), toHtml)
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Data.String (fromString)
import Data.Version
import qualified Data.Text.Lazy as LT
import Text.Markdown

import Prelude hiding (abs)

import Language.Futhark.TypeChecker (FileModule(..), Imports)
import Language.Futhark.TypeChecker.Monad hiding (NameMap, warn)
import Language.Futhark
import Futhark.Doc.Html
import Futhark.Version

-- | A set of names that we should not generate links to, because they
-- are uninteresting.  These are for example type parameters.
type NoLink = S.Set VName

data Context = Context { ctxCurrent :: String
                       , ctxFileMod :: FileModule
                       , ctxImports :: Imports
                       , ctxNoLink :: NoLink
                       , ctxNameMap :: NameMap
                       }
type NameMap = M.Map VName String
type DocM = ReaderT Context (Writer Warnings)

warn :: SrcLoc -> String -> DocM ()
warn loc s = tell $ singleWarning loc s

noLink :: [VName] -> DocM a -> DocM a
noLink names = local $ \ctx ->
  ctx { ctxNoLink = S.fromList names <> ctxNoLink ctx }

selfLink :: AttributeValue -> Html -> Html
selfLink s = H.a ! A.id s ! A.href ("#" <> s) ! A.class_ "self_link"

fullRow :: Html -> Html
fullRow = H.tr . (H.td ! A.colspan "3")

emptyRow :: Html
emptyRow = H.tr $ H.td mempty <> H.td mempty <> H.td mempty

specRow :: Html -> Html -> Html -> Html
specRow a b c = H.tr $ (H.td ! A.class_ "spec_lhs") a <>
                       (H.td ! A.class_ "spec_eql") b <>
                       (H.td ! A.class_ "spec_rhs") c

vnameToFileMap :: Imports -> NameMap
vnameToFileMap = mconcat . map forFile
  where forFile (file, FileModule abs file_env _prog) =
          mconcat (map vname (S.toList abs)) <>
          forEnv file_env
          where vname = flip M.singleton file . qualLeaf

                forEnv env =
                  mconcat (map vname $ M.elems $ envNameMap env) <>
                  mconcat (map forMod $ M.elems $ envModTable env)
                forMod (ModEnv env) = forEnv env
                forMod ModFun{} = mempty

renderFiles :: Imports -> ([(FilePath, Html)], Warnings)
renderFiles imports = runWriter $ do
  import_pages <- forM imports $ \(current, fm) ->
    let ctx = Context current fm imports mempty $ vnameToFileMap imports in
    flip runReaderT ctx $ do

    (first_paragraph, maybe_abstract, maybe_sections) <- headerDoc $ fileProg fm

    synopsis <- (H.div ! A.id "module") <$> synopsisDecs (progDecs $ fileProg fm)

    description <- describeDecs $ progDecs $ fileProg fm

    return (current,
            (H.docTypeHtml ! A.lang "en" $
             addBoilerplate current current $
             maybe_abstract <>
             selfLink "synopsis" (H.h2 "Synopsis") <> (H.div ! A.id "overview") synopsis <>
             selfLink "description" (H.h2 "Description") <> description <>
             maybe_sections,
             first_paragraph))

  return $
    ("index.html", indexPage $ map (fmap snd) import_pages) :
    map ((<.> "html") *** fst) import_pages

-- | The header documentation (which need not be present) can contain
-- an abstract and further sections.
headerDoc :: Prog -> DocM (Html, Html, Html)
headerDoc prog =
  case progDoc prog of
    Just (DocComment doc loc) -> do
      let (abstract, more_sections) = splitHeaderDoc doc
      first_paragraph <- docHtml $ Just $ DocComment (firstParagraph abstract) loc
      abstract' <- docHtml $ Just $ DocComment abstract loc
      more_sections' <- docHtml $ Just $ DocComment more_sections loc
      return (first_paragraph,
              selfLink "abstract" (H.h2 "Abstract") <> abstract',
              more_sections')
    _ -> return mempty
  where splitHeaderDoc s = fromMaybe (s, mempty) $
                           find (("\n##" `isPrefixOf`) . snd) $
                           zip (inits s) (tails s)
        firstParagraph = unlines . takeWhile (not . paragraphSeparator) . lines
        paragraphSeparator = all isSpace


indexPage :: [(String, Html)] -> Html
indexPage pages = H.docTypeHtml $ addBoilerplate "/" "Futhark Library Documentation" $
                  H.dl ! A.id "file_list" $
                  mconcat $ map linkTo $ sortBy (comparing fst) pages
  where linkTo (name, maybe_abstract) =
          let file = makeRelative "/" $ name -<.> "html"
          in (H.dt ! A.class_ "desc_header") (H.a ! A.href (fromString file) $ fromString name) <>
             (H.dd ! A.class_ "desc_doc") maybe_abstract

addBoilerplate :: String -> String -> Html -> Html
addBoilerplate current titleText bodyHtml =
  let headHtml = H.head $
                 H.meta ! A.charset "utf-8" <>
                 H.title (fromString titleText) <>
                 H.link ! A.href (fromString $ relativise "style.css" current)
                        ! A.rel "stylesheet"
                        ! A.type_ "text/css"

      navigation = H.a ! A.href (fromString $ relativise "index.html" current) $ "[root]"

      madeByHtml =
        "Generated by " <> (H.a ! A.href futhark_doc_url) "futhark-doc"
        <> " " <> fromString (showVersion version)
  in headHtml <> H.body (H.h1 (toHtml titleText) <>
                         (H.div ! A.id "navigation") navigation <>
                         (H.div ! A.id "content") bodyHtml <>
                         (H.div ! A.id "footer") madeByHtml)
  where futhark_doc_url =
          "https://futhark.readthedocs.io/en/latest/man/futhark-doc.html"

synopsisDecs :: [Dec] -> DocM Html
synopsisDecs decs = do
  fm <- asks ctxFileMod
  -- We add an empty row to avoid generating invalid HTML in cases
  -- where all rows are otherwise colspan=2.
  (H.table ! A.class_ "specs") . (emptyRow<>) . mconcat <$>
    sequence (mapMaybe (synopsisDec fm) decs)

synopsisDec :: FileModule -> Dec -> Maybe (DocM Html)
synopsisDec fm dec = case dec of
  SigDec s -> synopsisModType s
  ModDec m -> synopsisMod fm m
  ValDec v -> synopsisValBind v
  TypeDec t -> synopsisType t
  OpenDec x xs (Info _names) _
    | Just opened <- mapM synopsisOpened (x:xs) -> Just $ do
        opened' <- sequence opened
        return $ fullRow $ "open " <> mconcat (intersperse " " opened')
    | otherwise ->
        Just $ return $ fullRow $
        fromString $ "open <" <> unwords (map pretty $ x:xs) ++ ">"
  LocalDec _ _ -> Nothing

synopsisOpened :: ModExp -> Maybe (DocM Html)
synopsisOpened (ModVar qn _) = Just $ vnameDescDef $ qualLeaf qn
synopsisOpened (ModParens me _) = do me' <- synopsisOpened me
                                     Just $ parens <$> me'
synopsisOpened (ModImport _ (Info file) _) = Just $ do
  current <- asks ctxCurrent
  let dest = fromString $ relativise file current <> ".html"
  return $ "import " <> (H.a ! A.href dest) (fromString $ show file)
synopsisOpened (ModAscript _ se _ _) = Just $ do
  se' <- synopsisSigExp se
  return $ "... : " <> se'
synopsisOpened _ = Nothing

synopsisValBind :: ValBind -> Maybe (DocM Html)
synopsisValBind vb = Just $ do
  let name' = vnameSynopsisDef $ valBindName vb
  (lhs, mhs, rhs) <- valBindHtml name' vb
  return $ specRow lhs (mhs <> " : ") rhs

valBindHtml :: Html -> ValBind -> DocM (Html, Html, Html)
valBindHtml name (ValBind _ _ retdecl (Info rettype) tparams params _ _ _) = do
  let tparams' = mconcat $ map ((" "<>) . typeParamHtml) tparams
      noLink' = noLink $ map typeParamName tparams ++
                map identName (S.toList $ mconcat $ map patIdentSet params)
  rettype' <- noLink' $ maybe (typeHtml rettype) typeExpHtml retdecl
  params' <- noLink' $ mapM patternHtml params
  return ("val " <> (H.span ! A.class_ "decl_name") name,
          tparams',
          mconcat (intersperse " -> " $ params' ++ [rettype']))

synopsisModType :: SigBind -> Maybe (DocM Html)
synopsisModType sb = Just $ do
  let name' = vnameSynopsisDef $ sigName sb
  fullRow <$> do
    se' <- synopsisSigExp $ sigExp sb
    return $ "module type " <> name' <> " = " <> se'

synopsisMod :: FileModule -> ModBind -> Maybe (DocM Html)
synopsisMod fm (ModBind name ps sig _ _ _) =
  case sig of Nothing    -> (proceed <=< envSig) <$> M.lookup name modtable
              Just (s,_) -> Just $ proceed =<< synopsisSigExp s
  where proceed sig' = do
          let name' = vnameSynopsisDef name
          ps' <- modParamHtml ps
          return $ specRow ("module " <> name') ": " (ps' <> sig')

        FileModule _abs Env { envModTable = modtable} _ = fm
        envSig (ModEnv e) = renderEnv e
        envSig (ModFun (FunSig _ _ (MTy _ m))) = envSig m

synopsisType :: TypeBind -> Maybe (DocM Html)
synopsisType tb = Just $ do
  let name' = vnameSynopsisDef $ typeAlias tb
  fullRow <$> typeBindHtml name' tb

typeBindHtml :: Html -> TypeBind -> DocM Html
typeBindHtml name' (TypeBind _ tparams t _ _) = do
  t' <- noLink (map typeParamName tparams) $ typeDeclHtml t
  return $ typeAbbrevHtml name' tparams <> " = " <> t'

renderEnv :: Env -> DocM Html
renderEnv (Env vtable ttable sigtable modtable _) = do
  typeBinds <- mapM renderTypeBind (M.toList ttable)
  valBinds <- mapM renderValBind (M.toList vtable)
  sigBinds <- mapM renderModType (M.toList sigtable)
  modBinds <- mapM renderMod (M.toList modtable)
  return $ braces $ mconcat $ typeBinds ++ valBinds ++ sigBinds ++ modBinds

renderModType :: (VName, MTy) -> DocM Html
renderModType (name, _sig) =
  ("module type " <>) <$> qualNameHtml (qualName name)

renderMod :: (VName, Mod) -> DocM Html
renderMod (name, _mod) =
  ("module " <>) <$> qualNameHtml (qualName name)

renderValBind :: (VName, BoundV) -> DocM Html
renderValBind = fmap H.div . synopsisValBindBind

renderTypeBind :: (VName, TypeBinding) -> DocM Html
renderTypeBind (name, TypeAbbr tps tp) = do
  tp' <- typeHtml tp
  return $ H.div $ typeAbbrevHtml (vnameHtml name) tps <> " = " <> tp'

synopsisValBindBind :: (VName, BoundV) -> DocM Html
synopsisValBindBind (name, BoundV tps t) = do
  let tps' = map typeParamHtml tps
  t' <- typeHtml t
  return $ "val " <> vnameHtml name <> joinBy " " tps' <> ": " <> t'

typeHtml :: StructType -> DocM Html
typeHtml t = case t of
  Prim et -> return $ primTypeHtml et
  Record fs
    | Just ts <- areTupleFields fs ->
        parens . commas <$> mapM typeHtml ts
    | otherwise ->
        braces . commas <$> mapM ppField (M.toList fs)
    where ppField (name, tp) = do
            tp' <- typeHtml tp
            return $ toHtml (nameToString name) <> ": " <> tp'
  TypeVar et targs -> do
    targs' <- mapM typeArgHtml targs
    et' <- typeNameHtml et
    return $ et' <> joinBy " " targs'
  Array et shape u -> do
    shape' <- prettyShapeDecl shape
    et' <- prettyElem et
    return $ prettyU u <> shape' <> et'
  Arrow _ pname t1 t2 -> do
    t1' <- typeHtml t1
    t2' <- typeHtml t2
    return $ case pname of
      Just v ->
        parens (vnameHtml v <> ": " <> t1') <> " -> " <> t2'
      Nothing ->
        t1' <> " -> " <> t2'

prettyElem :: ArrayElemTypeBase (DimDecl VName) () -> DocM Html
prettyElem (ArrayPrimElem et _) = return $ primTypeHtml et
prettyElem (ArrayPolyElem et targs _) = do
  targs' <- mapM typeArgHtml targs
  return $ prettyTypeName et <> joinBy " " targs'
prettyElem (ArrayRecordElem fs)
  | Just ts <- areTupleFields fs =
      parens . commas <$> mapM prettyRecordElem ts
  | otherwise =
      braces . commas <$> mapM ppField (M.toList fs)
  where ppField (name, tp) = do
          tp' <- prettyRecordElem tp
          return $ toHtml (nameToString name) <> ": " <> tp'

prettyRecordElem :: RecordArrayElemTypeBase (DimDecl VName) () -> DocM Html
prettyRecordElem (RecordArrayElem et) = prettyElem et
prettyRecordElem (RecordArrayArrayElem et shape u) =
  typeHtml $ Array et shape u

prettyShapeDecl :: ShapeDecl (DimDecl VName) -> DocM Html
prettyShapeDecl (ShapeDecl ds) =
  mconcat <$> mapM (fmap brackets . dimDeclHtml) ds

typeArgHtml :: TypeArg (DimDecl VName) () -> DocM Html
typeArgHtml (TypeArgDim d _) = brackets <$> dimDeclHtml d
typeArgHtml (TypeArgType t _) = typeHtml t

modParamHtml :: [ModParamBase Info VName] -> DocM Html
modParamHtml [] = return mempty
modParamHtml (ModParam pname psig _ _ : mps) =
  liftM2 f (synopsisSigExp psig) (modParamHtml mps)
  where f se params = "(" <> vnameHtml pname <>
                      ": " <> se <> ") -> " <> params

synopsisSigExp :: SigExpBase Info VName -> DocM Html
synopsisSigExp e = case e of
  SigVar v _ -> qualNameHtml v
  SigParens e' _ -> parens <$> synopsisSigExp e'
  SigSpecs ss _ -> braces . (H.table ! A.class_ "specs") . mconcat <$> mapM synopsisSpec ss
  SigWith s (TypeRef v t _) _ -> do
    s' <- synopsisSigExp s
    t' <- typeDeclHtml t
    v' <- qualNameHtml v
    return $ s' <> " with " <> v' <> " = " <> t'
  SigArrow Nothing e1 e2 _ ->
    liftM2 f (synopsisSigExp e1) (synopsisSigExp e2)
    where f e1' e2' = e1' <> " -> " <> e2'
  SigArrow (Just v) e1 e2 _ ->
    do name <- vnameDescDef v
       e1' <- synopsisSigExp e1
       e2' <- synopsisSigExp e2
       return $ "(" <> name <> ": " <> e1' <> ") -> " <> e2'

vnameHtml :: VName -> Html
vnameHtml (VName name tag) =
  H.span ! A.id (fromString (show tag)) $ renderName name

vnameDescDef :: VName -> DocM Html
vnameDescDef v =
  return $ H.a ! A.id (fromString (show (baseTag v))) $ renderName (baseName v)

vnameSynopsisDef :: VName -> Html
vnameSynopsisDef (VName name tag) =
  H.span ! A.id (fromString (show tag ++ "s")) $
  H.a ! A.href (fromString ("#" ++ show tag)) $ renderName name

vnameSynopsisRef :: VName -> Html
vnameSynopsisRef v = H.a ! A.class_ "synopsis_link"
                         ! A.href (fromString ("#" ++ show (baseTag v) ++ "s")) $
                     "↑"

synopsisSpec :: SpecBase Info VName -> DocM Html
synopsisSpec spec = case spec of
  TypeAbbrSpec tpsig ->
    fullRow <$> typeBindHtml (vnameSynopsisDef $ typeAlias tpsig) tpsig
  TypeSpec name ps _ _ ->
    return $ fullRow $ "type " <> vnameSynopsisDef name <> joinBy " " (map typeParamHtml ps)
  ValSpec name tparams rettype _ _ -> do
    let tparams' = map typeParamHtml tparams
    rettype' <- noLink (map typeParamName tparams) $
                typeDeclHtml rettype
    return $ specRow
      ("val " <> vnameSynopsisDef name)
      (mconcat (map (" "<>) tparams') <> ": ") rettype'
  ModSpec name sig _ _ ->
    specRow ("module " <> vnameSynopsisDef name) ": " <$> synopsisSigExp sig
  IncludeSpec e _ -> fullRow . ("include " <>) <$> synopsisSigExp e

typeDeclHtml :: TypeDeclBase f VName -> DocM Html
typeDeclHtml = typeExpHtml . declaredType

typeExpHtml :: TypeExp VName -> DocM Html
typeExpHtml e = case e of
  TEUnique t _  -> ("*"<>) <$> typeExpHtml t
  TEArray at d _ -> do
    at' <- typeExpHtml at
    d' <- dimDeclHtml d
    return $ brackets d' <> at'
  TETuple ts _ -> parens . commas <$> mapM typeExpHtml ts
  TERecord fs _ -> braces . commas <$> mapM ppField fs
    where ppField (name, t) = do
            t' <- typeExpHtml t
            return $ toHtml (nameToString name) <> ": " <> t'
  TEVar name  _ -> qualNameHtml name
  TEApply t arg _ -> do
    t' <- typeExpHtml t
    arg' <- typeArgExpHtml arg
    return $ t' <> " " <> arg'
  TEArrow pname t1 t2 _ -> do
    t1' <- typeExpHtml t1
    t2' <- typeExpHtml t2
    return $ case pname of
      Just v ->
        parens $ (vnameHtml v <> ": " <> t1') <> " -> " <> t2'
      Nothing ->
        t1' <> " -> " <> t2'

qualNameHtml :: QualName VName -> DocM Html
qualNameHtml (QualName names vname@(VName name tag)) =
  if tag <= maxIntrinsicTag
      then return $ renderName name
      else f <$> ref
  where prefix :: Html
        prefix = mapM_ ((<> ".") . renderName . baseName) names
        f (Just s) = H.a ! A.href (fromString s) $ prefix <> renderName name
        f Nothing = prefix <> renderName name

        ref = do boring <- asks $ S.member vname . ctxNoLink
                 if boring
                   then return Nothing
                   else Just <$> vnameLink vname

vnameLink :: VName -> DocM String
vnameLink vname@(VName _ tag) = do
  current <- asks ctxCurrent
  file <- fromMaybe current <$> asks (M.lookup vname . ctxNameMap)
  if file == current
    then return $ "#" ++ show tag
    else return $ relativise file current ++ ".html#" ++ show tag

typeNameHtml :: TypeName -> DocM Html
typeNameHtml = qualNameHtml . qualNameFromTypeName

patternHtml :: Pattern -> DocM Html
patternHtml pat = do
  let (pat_param, t) = patternParam pat
  t' <- typeHtml t
  return $ case pat_param of
             Just v  -> parens (vnameHtml v <> ": " <> t')
             Nothing -> t'

relativise :: FilePath -> FilePath -> FilePath
relativise dest src =
  concat (replicate (length (splitPath src) - 2) "../") ++ dest

dimDeclHtml :: DimDecl VName -> DocM Html
dimDeclHtml AnyDim = return mempty
dimDeclHtml (NamedDim v) = qualNameHtml v
dimDeclHtml (ConstDim n) = return $ toHtml (show n)

typeArgExpHtml :: TypeArgExp VName -> DocM Html
typeArgExpHtml (TypeArgExpDim d _) = dimDeclHtml d
typeArgExpHtml (TypeArgExpType d) = typeExpHtml d

typeParamHtml :: TypeParam -> Html
typeParamHtml (TypeParamDim name _) = brackets $ vnameHtml name
typeParamHtml (TypeParamType name _) = "'" <> vnameHtml name
typeParamHtml (TypeParamLiftedType name _) = "'^" <> vnameHtml name

typeAbbrevHtml :: Html -> [TypeParam] -> Html
typeAbbrevHtml name params =
  "type " <> name <> joinBy " " (map typeParamHtml params)

docHtml :: Maybe DocComment -> DocM Html
docHtml (Just (DocComment doc loc)) =
  markdown def { msAddHeadingId = True } . LT.pack <$> identifierLinks loc doc
docHtml Nothing = return mempty

identifierLinks :: SrcLoc -> String -> DocM String
identifierLinks _ [] = return []
identifierLinks loc s
  | Just ((name, namespace, file), s') <- identifierReference s = do
      let proceed x = (x<>) <$> identifierLinks loc s'
          unknown = proceed $ "`" <> name <> "`"
      case knownNamespace namespace of
        Just namespace' -> do
          maybe_v <- lookupName (namespace', name, file)
          case maybe_v of
            Nothing -> do
              warn loc $
                "Identifier '" <> name <> "' not found in namespace '" <>
                namespace <> "'" <> maybe "" (" in file "<>) file <> "."
              unknown
            Just v' -> do
              link <- vnameLink v'
              proceed $ "[`" <> name <> "`](" <> link <> ")"
        _ -> do
          warn loc $ "Unknown namespace '" <> namespace <> "'."
          unknown
  where knownNamespace "term" = Just Term
        knownNamespace "mtype" = Just Signature
        knownNamespace "type" = Just Type
        knownNamespace _ = Nothing
identifierLinks loc (c:s') = (c:) <$> identifierLinks loc s'

lookupName :: (Namespace, String, Maybe FilePath) -> DocM (Maybe VName)
lookupName (namespace, name, file) = do
  env <- lookupEnvForFile file
  case M.lookup (namespace, nameFromString name) . envNameMap =<< env of
    Nothing -> return Nothing
    Just qn -> return $ Just $ qualLeaf qn

lookupEnvForFile :: Maybe FilePath -> DocM (Maybe Env)
lookupEnvForFile Nothing     = asks $ Just . fileEnv . ctxFileMod
lookupEnvForFile (Just file) = asks $ fmap fileEnv . lookup file . ctxImports

describeGeneric :: VName
                -> Maybe DocComment
                -> (Html -> DocM Html)
                -> DocM Html
describeGeneric name doc f = do
  name' <- H.span ! A.class_ "decl_name" <$> vnameDescDef name
  decl_type <- f name'
  doc' <- docHtml doc
  let decl_doc = H.dd ! A.class_ "desc_doc" $ doc'
      decl_header = (H.dt ! A.class_ "desc_header") $
                    vnameSynopsisRef name <> decl_type
  return $ decl_header <> decl_doc

describeGenericMod :: VName
                   -> SigExp
                   -> Maybe DocComment
                   -> (Html -> DocM Html)
                   -> DocM Html
describeGenericMod name se doc f = do
  name' <- H.span ! A.class_ "decl_name" <$> vnameDescDef name

  decl_type <- f name'

  doc' <- case se of
            SigSpecs specs _ -> (<>) <$> docHtml doc <*> describeSpecs specs
            _                -> docHtml doc

  let decl_doc = H.dd ! A.class_ "desc_doc" $ doc'
      decl_header = (H.dt ! A.class_ "desc_header") $
                    vnameSynopsisRef name <> decl_type
  return $ decl_header <> decl_doc

describeDecs :: [Dec] -> DocM Html
describeDecs decs = do
  fm <- asks ctxFileMod
  H.dl . mconcat <$>
    mapM (fmap $ H.div ! A.class_ "decl_description")
    (mapMaybe (describeDec fm) decs)

describeDec :: FileModule -> Dec -> Maybe (DocM Html)
describeDec _ (ValDec vb) = Just $
  describeGeneric (valBindName vb) (valBindDoc vb) $ \name -> do
  (lhs, mhs, rhs) <- valBindHtml name vb
  return $ lhs <> mhs <> ": " <> rhs

describeDec _ (TypeDec vb) = Just $
  describeGeneric (typeAlias vb) (typeDoc vb) (`typeBindHtml` vb)

describeDec _ (SigDec (SigBind name se doc _)) = Just $
  describeGenericMod name se doc $ \name' ->
  return $ "module type " <> name'

describeDec _ (ModDec mb) = Just $
  describeGeneric (modName mb) (modDoc mb) $ \name' ->
  return $ "module " <> name'

describeDec _ OpenDec{} = Nothing
describeDec _ LocalDec{} = Nothing

describeSpecs :: [Spec] -> DocM Html
describeSpecs specs =
  H.dl . mconcat <$> mapM describeSpec specs

describeSpec :: Spec -> DocM Html
describeSpec (ValSpec name tparams t doc _) =
  describeGeneric name doc $ \name' -> do
    let tparams' = mconcat $ map ((" "<>) . typeParamHtml) tparams
    t' <- noLink (map typeParamName tparams) $
          typeExpHtml $ declaredType t
    return $ "val " <>  name' <> tparams' <> ": " <> t'
describeSpec (TypeAbbrSpec vb) =
  describeGeneric (typeAlias vb) (typeDoc vb) (`typeBindHtml` vb)
describeSpec (TypeSpec name tparams doc _) =
  describeGeneric name doc $ return . (`typeAbbrevHtml` tparams)
describeSpec (ModSpec name se doc _) =
  describeGenericMod name se doc $ \name' ->
  case se of
    SigSpecs{} -> return $ "module " <> name'
    _ -> do se' <- synopsisSigExp se
            return $ "module " <> name' <> ": " <> se'
describeSpec (IncludeSpec sig _) = do
  sig' <- synopsisSigExp sig
  doc' <- docHtml Nothing
  let decl_header = (H.dt ! A.class_ "desc_header") $
                    (H.span ! A.class_ "synopsis_link") mempty <>
                    "include " <>
                    sig'
      decl_doc = H.dd ! A.class_ "desc_doc" $ doc'
  return $ decl_header <> decl_doc
