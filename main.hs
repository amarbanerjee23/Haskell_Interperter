import ASTParser
import Data.List as List
import qualified Data.Map as Map

data Value = NullVal
  | Numeric Int
  | Booleric Bool
  | Func [ID] AST [Env]
  deriving (Show) 

type Store = Map.Map Int Value
newStore :: Store
newStore = Map.empty
newRef :: Store -> Int -> Store
newRef str ref = Map.insert ref NullVal str
setRef :: Store -> Int -> Value -> Store
setRef str ref val = Map.insert ref val str
deRef :: Store -> Int -> Value
deRef str ref =
  let v = Map.lookup ref str
  in case v of Just n -> n
               Nothing -> error "variable not found"

data Env = EBind ID Value deriving (Show)

extendBindEnv :: Binding -> [Env] -> Store -> (Env, Store)
extendBindEnv bind env str =
  case bind of (Bind id (Number n)) -> ((EBind id (Numeric n)), str)
               (Bind id (Boolean b)) -> ((EBind id (Booleric b)), str)
               (Bind id (Function formals body)) -> ((EBind id (Func formals body env)), str)
               (Bind id ast) -> let (v, str') = evaluateAst env str ast in ((EBind id v), str')
               

elaborateEnv :: [Binding] -> [Env] -> Store -> ([Env], Store)
elaborateEnv [] env str = (env, str)
elaborateEnv [b] env str = 
  let (vb, str') = extendBindEnv b env str
  in  ([vb], str')
elaborateEnv (b:b') env str = 
  let (vb, str') = extendBindEnv b env str
  in
    let (vb', str'') = elaborateEnv b' env str'
    in ((vb:vb'), str'')

extendEnv :: [Env] -> [Binding] -> Store -> ([Env], Store)
extendEnv env binds str =
    -- take a binding, convert it to vbind
    let (vbinds, str') = elaborateEnv binds env str
    in 
      let vb' = List.unionBy (\(EBind i v) (EBind j v') -> i == j) env vbinds
      in (vb', str')

lookupEnv :: [Env] -> ID -> Value
lookupEnv env id =
  (\(EBind i v) -> v) $ head $ filter (\(EBind i v) -> i == id) env
evaluateAst :: [Env] -> Store -> AST -> (Value, Store)
evaluateAst env str ast =
  case ast of (Number n) -> ((Numeric n), str)

              (Boolean b) -> ((Booleric b), str)

              (Reference id) -> (lookupEnv env id, str)

              (Assume bindings ast) -> evaluateAst env' str' ast 
                                    where (env', str')  = extendEnv env bindings str

              (If i t e) -> evaluateConditions env str i t e

              (App ((Reference id): args)) -> apply env str id args

              (NewRef id) -> (NullVal, newRef str' (getNumberValue id')) 
                         where (id', str') = evaluateAst env str id

              (SetRef id val) -> let (val', str') = evaluateAst env str val
                                 in let (id', str'') = evaluateAst env str' id
                                 in  (val', setRef str'' (getNumberValue id') val')

              (DeRef id) -> let (id', str') = evaluateAst env str id
                            in  let v = deRef str (getNumberValue id')
                            in (v, str')

              (Sequence alist) -> evaluateAst_sequence alist env str

              _ -> error "unexpected!"

evaluateAst' :: [Binding] -> AST -> Value
evaluateAst' env ast = v
                    where (v,s) = evaluateAst env' str' ast
                                where (env', str') = extendEnv [] env str
                                                    where str = newStore

evaluateOperations :: [Env] -> Store -> ID -> [AST] -> (Value, Store)
evaluateOperations env str op args
  | elem op ["+", "-", "*", "/"] = 
      let (v1, str') = evaluateAst env str (args!!0)
      in
    let v1' = getNumberValue v1
        (v2, str'') = evaluateAst env str' (args!!1)
    in
        let v2' = getNumberValue v2
        in (evaluateBinaryNumberOperations op v1' v2', str'')
  | elem op ["|", "&"] = 
      let (v1, str') = evaluateAst env str (args!!0)
      in
        let v1' = getBooleanValue v1
            (v2, str'') = evaluateAst env str' (args!!1)
        in
          let v2' = getBooleanValue v2
          in (evaluateBooleanOperations op v1' v2', str'')
  | op == "~" = 
      let (v, str') = evaluateAst env str (args!!0)
      in
      (evaluateUnaryBooleanOperations op (getBooleanValue v), str')
  | op == "zero?" = 
      let (v, str') = evaluateAst env str (args!!0)
      in
      (evaluateUnaryNumberOperations op (getNumberValue v), str')
  | otherwise = error "op error."

evaluateAst_sequence :: [AST] -> [Env] -> Store -> (Value, Store)
evaluateAst_sequence [ast] env str =
  evaluateAst env str ast
evaluateAst_sequence (ast:alist') env str =  
  let (v, str') = evaluateAst env str ast
  in
    evaluateAst_sequence alist' env str'

evaluateBinaryNumberOperations :: ID -> Int -> Int -> Value
evaluateBinaryNumberOperations op v v'
  | op == "+" = Numeric (v + v')
  | op == "-" = Numeric (v - v')
  | op == "*" = Numeric (v * v')
  | op == "/" = Numeric (div v v')


evaluateBooleanOperations :: ID -> Bool -> Bool -> Value
evaluateBooleanOperations op v v'
  | op == "|" = Booleric (v || v')
  | op == "&" = Booleric (v && v')

evaluateUnaryBooleanOperations :: ID -> Bool -> Value
evaluateUnaryBooleanOperations op v
  | op == "~" = Booleric (not v)

evaluateUnaryNumberOperations :: ID -> Int -> Value
evaluateUnaryNumberOperations op v
  | op == "zero?" = Booleric $ if v == 0 then True else False

evaluateConditions :: [Env] -> Store -> AST -> AST -> AST -> (Value, Store)
evaluateConditions env str ia ta ea =
  let (t, str') = evaluateAst env str ia
  in
    case t of (Booleric b) -> if b then (evaluateAst env str' ta) else (evaluateAst env str' ea)
              _ -> error "Unexpected value!"
apply :: [Env] -> Store -> ID -> [AST] -> (Value, Store)
apply env str id args
  | checkOp id = evaluateOperations env str id args
  | (checkFunction env id) = applyFunctionClosure env str id args
  | otherwise = error "unexpected error"

applyFunctionClosure :: [Env] -> Store -> ID -> [AST] -> (Value, Store)
applyFunctionClosure env str id args =
  let (Func formals body senv) = lookupEnv env id
  in
    let minienv = (List.zipWith (\i a -> (Bind i a)) formals args)
    in 
      let (env', str') = extendEnv senv minienv str
      in
      evaluateAst env' str' body

checkOp :: ID -> Bool
checkOp id = elem id ["+", "-", "*", "/", "|", "&", "~"]

checkFunction :: [Env] -> ID -> Bool
checkFunction env id =
  case (lookupEnv env id) of
      (Func i a e) -> True
      _ -> False

getNumberValue (Numeric n) = n
getBooleanValue (Booleric b) = b

run = ((evaluateAst' []) . parseString)
